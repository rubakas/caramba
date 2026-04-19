require "socket"
require "json"

module Caramba
  # Bonjour advertisement of the Rails API server. Keeps the decision
  # logic (should we advertise? what port? what service name?) in plain
  # methods so it can be unit-tested without booting Puma or spawning a
  # real dns-sd subprocess.
  module Bonjour
    DNS_SD_PATH = "/usr/bin/dns-sd".freeze
    SERVICE_TYPE = "_caramba._tcp".freeze
    DEFAULT_BEACON_PORT = 3999

    module_function

    # Resolve the port the server will actually listen on. Order:
    #   1. `-p N` / `--port N` / `--port=N` on the CLI (what `rails server
    #      -p 3001` passes through), because that flag does NOT set
    #      ENV["PORT"].
    #   2. ENV["PORT"] (what Puma reads by default, what our Procfile sets).
    #   3. Rails default 3000.
    #
    # Shells and launch agents often have PORT already set to something
    # unrelated (macOS exports PORT=5000 for AirPlay Receiver), so we
    # cannot trust ENV blindly — CLI wins.
    def resolve_port(argv: ARGV, env: ENV, default: 3000)
      i = 0
      while i < argv.length
        arg = argv[i]
        if arg =~ /\A--port=(\d+)\z/
          return $1.to_i
        end
        if (arg == "-p" || arg == "--port") && argv[i + 1] =~ /\A\d+\z/
          return argv[i + 1].to_i
        end
        i += 1
      end
      (env["PORT"] || default.to_s).to_i
    end

    # The mDNS instance name the server registers. Distinct per host+port
    # so dev (3001) and prod (3000) on the same machine don't collide.
    def service_name(hostname:, port:)
      "Caramba (#{hostname}:#{port})"
    end

    # Strip a trailing `.local` / `.local.` from a hostname. Exposed as a
    # pure function so tests don't need to stub Socket.gethostname.
    def normalize_hostname(raw)
      raw.sub(/\.local\.?\z/, "")
    end

    # Short hostname, with any trailing `.local` stripped so it matches
    # what the user sees in their system preferences.
    def hostname
      normalize_hostname(Socket.gethostname)
    end

    # Should the initializer run mDNS advertisement? mDNS needs the
    # system `dns-sd` binary, which is macOS-only here.
    def should_advertise?(env: ENV, rails_env: Rails.env, platform: RUBY_PLATFORM, program_name: $PROGRAM_NAME)
      return false unless should_beacon?(env: env, rails_env: rails_env, program_name: program_name)
      return false if env["CARAMBA_DISABLE_MDNS"] == "1"
      return false unless platform.include?("darwin")
      true
    end

    # Should the initializer run the discovery beacon? The beacon is
    # pure Ruby (a tiny TCP listener), so platform is irrelevant — but we
    # still skip under the same non-HTTP-serving contexts as mDNS.
    def should_beacon?(env: ENV, rails_env: Rails.env, program_name: $PROGRAM_NAME)
      return false if rails_env.to_s == "test"
      return false if env["CARAMBA_DISABLE_DISCOVERY"] == "1"
      return false if defined?(Rails::Console)
      return false if File.basename(program_name) == "rake"
      true
    end

    # The exact argv array passed to Process.spawn. Exposed so tests can
    # assert on its contents without running the process.
    def dns_sd_argv(port:, hostname:, version:, bin: DNS_SD_PATH)
      [
        bin,
        "-R", service_name(hostname: hostname, port: port),
        SERVICE_TYPE, ".",
        port.to_s,
        "name=#{hostname}",
        "version=#{version}",
        "port=#{port}",
        "path=/api",
      ]
    end

    # Read REVISION (Capistrano writes it at deploy time) or fall back to
    # "dev". Kept here so the initializer stays tiny.
    def version(root: Rails.root)
      File.read(root.join("..", "REVISION")).strip
    rescue Errno::ENOENT
      "dev"
    end

    # --- Discovery beacon --------------------------------------------
    # The beacon is a tiny hand-rolled HTTP listener on a well-known
    # port. Clients that can't do mDNS (Android WebView, Linux / Windows
    # browsers) subnet-scan this port; the beacon answers with the real
    # Rails URL and metadata so the client doesn't need to know anything
    # about the server's actual port.

    # Resolve the beacon port. `CARAMBA_DISCOVERY_PORT` wins; otherwise
    # DEFAULT_BEACON_PORT. Falls back to the default when the env value
    # is non-numeric.
    def beacon_port(env: ENV)
      raw = env["CARAMBA_DISCOVERY_PORT"]
      return DEFAULT_BEACON_PORT unless raw =~ /\A\d+\z/
      raw.to_i
    end

    # Build the JSON body the beacon sends. The client constructs the
    # real URL using the host it reached the beacon on (so Android
    # emulator NAT, WireGuard, multi-interface hosts all work) plus the
    # application port we advertise here.
    def beacon_payload(port:, hostname:, version:)
      JSON.generate(
        {
          "status" => "ok",
          "port" => port,
          "server_name" => hostname,
          "version" => version,
        }
      )
    end

    # Bind a TCP listener on `port` and answer each connection with
    # `payload` inside a minimal HTTP/1.1 response. Runs in its own
    # daemon thread so it never blocks Rails boot. Dependencies are
    # injected so tests can drive it synchronously with a fake server.
    #
    # Returns the `Thread` on success, `nil` on bind failure (in which
    # case the initializer just carries on — Electron clients still have
    # mDNS; everyone else falls back to manual entry).
    def start_beacon!(port:, payload:,
                      server_factory: ->(p) { TCPServer.new("0.0.0.0", p) },
                      at_exit_registrar: Kernel.method(:at_exit),
                      logger: nil, stderr: $stderr)
      # Explicitly bind to all IPv4 interfaces. On some Rubies / macOS
      # configurations a bare `TCPServer.new(port)` picks a host that
      # only accepts localhost traffic, which would block Android
      # emulator NAT (emulator reaches the host via 10.0.2.2, an IPv4
      # alias) and LAN peers.
      server = server_factory.call(port)

      thread = Thread.new do
        serve_beacon_loop(server, payload)
      end
      thread.name = "caramba-beacon" if thread.respond_to?(:name=)
      thread.report_on_exception = false if thread.respond_to?(:report_on_exception=)

      at_exit_registrar.call do
        begin
          server.close unless server.closed?
        rescue StandardError
          # ignore — process is going down anyway
        end
      end

      msg = "[bonjour] discovery beacon listening on :#{port}"
      logger&.info(msg)
      stderr.puts(msg)
      thread
    rescue Errno::EADDRINUSE
      warn_msg = "[bonjour] beacon port #{port} in use, skipping discovery beacon"
      logger&.warn(warn_msg)
      stderr.puts(warn_msg)
      nil
    rescue StandardError => e
      warn_msg = "[bonjour] beacon failed to start — #{e.class}: #{e.message}"
      logger&.warn(warn_msg)
      stderr.puts(warn_msg)
      nil
    end

    # Internal: accept one connection at a time, write the payload, close.
    # Exits the loop when the server is closed (at shutdown) or when a
    # test's fake `accept` raises IOError to signal exhaustion.
    def serve_beacon_loop(server, payload)
      response = beacon_http_response(payload)
      loop do
        client =
          begin
            server.accept
          rescue IOError, Errno::EBADF
            break
          end

        begin
          client.write(response)
        rescue StandardError
          # The client may have already hung up; just drop it.
        ensure
          begin
            client.close
          rescue StandardError
          end
        end
      end
    end

    def beacon_http_response(payload)
      body = payload.to_s
      # CRLF line endings per RFC 7230. Connection: close lets the client
      # (fetch) see EOF and resolve immediately without pooling.
      #
      # Access-Control-Allow-Origin is required so browsers and Capacitor
      # WebViews can read the response body — without it, the request
      # succeeds at the network layer but JS can't parse the JSON (the
      # symptom is "No servers found" even though the beacon responded).
      [
        "HTTP/1.1 200 OK",
        "Content-Type: application/json",
        "Access-Control-Allow-Origin: *",
        "Connection: close",
        "Content-Length: #{body.bytesize}",
        "",
        body,
      ].join("\r\n")
    end

    # --- dns-sd advertisement ----------------------------------------

    # Spawn dns-sd and return its pid. Installs an at_exit hook that
    # terminates the subprocess so short-lived Rails invocations don't
    # leak advertisers. The spawner / detacher / at_exit_registrar
    # dependencies are injectable so this can be tested without actually
    # running a subprocess or installing a real at_exit hook.
    def advertise!(port:, hostname:, version:,
                   logger: nil, stderr: $stderr,
                   spawner: Process.method(:spawn),
                   detacher: Process.method(:detach),
                   at_exit_registrar: Kernel.method(:at_exit))
      argv = dns_sd_argv(port: port, hostname: hostname, version: version)
      pid = spawner.call(*argv, out: File::NULL, err: stderr)
      detacher.call(pid)
      at_exit_registrar.call { Process.kill("TERM", pid) rescue Errno::ESRCH }

      msg = "[bonjour] advertising #{SERVICE_TYPE} on :#{port} as '#{service_name(hostname: hostname, port: port)}' (pid #{pid})"
      logger&.info(msg)
      stderr.puts(msg)
      pid
    rescue Errno::ENOENT
      warn_msg = "[bonjour] dns-sd not found at #{DNS_SD_PATH}, skipping advertisement"
      logger&.warn(warn_msg)
      stderr.puts(warn_msg)
      nil
    rescue => e
      warn_msg = "[bonjour] advertise failed — #{e.class}: #{e.message}"
      logger&.warn(warn_msg)
      stderr.puts(warn_msg)
      nil
    end
  end
end
