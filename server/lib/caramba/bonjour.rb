require "socket"

module Caramba
  # mDNS advertisement of the Rails API server. Shells out to macOS
  # `dns-sd` to publish a `_caramba._tcp` record so Electron clients
  # (which embed bonjour-service) can discover the server without any
  # manual configuration. Browsers and Capacitor WebViews can't do mDNS;
  # they discover via HTTP subnet scan against `/api/health` on the
  # known Rails ports — no advertisement needed for that path.
  module Bonjour
    DNS_SD_PATH = "/usr/bin/dns-sd".freeze
    SERVICE_TYPE = "_caramba._tcp".freeze

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

    # Strip a trailing `.local` / `.local.` from a hostname. Exposed as a
    # pure function so tests don't need to stub Socket.gethostname.
    def normalize_hostname(raw)
      raw.sub(/\.local\.?\z/, "")
    end

    def hostname
      normalize_hostname(Socket.gethostname)
    end

    # mDNS instance name. Distinct per host+port so dev (3001) and prod
    # (3000) on the same machine don't collide.
    def service_name(hostname:, port:)
      "Caramba (#{hostname}:#{port})"
    end

    # Should the initializer try to advertise? mDNS needs the system
    # `dns-sd` binary (macOS only).
    def should_advertise?(env: ENV, rails_env: Rails.env, platform: RUBY_PLATFORM, program_name: $PROGRAM_NAME)
      return false if rails_env.to_s == "test"
      return false if env["CARAMBA_DISABLE_MDNS"] == "1"
      return false unless platform.include?("darwin")
      return false if defined?(Rails::Console)
      return false if File.basename(program_name) == "rake"
      true
    end

    # Exact argv passed to Process.spawn. Kept module-level so tests can
    # assert on its shape.
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
    # "dev".
    def version(root: Rails.root)
      File.read(root.join("..", "REVISION")).strip
    rescue Errno::ENOENT
      "dev"
    end

    # Spawn dns-sd and return its pid. Installs an at_exit hook that
    # terminates the subprocess so short-lived Rails invocations don't
    # leak advertisers. Dependencies are injectable for tests.
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
