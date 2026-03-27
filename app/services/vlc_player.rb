# Manages VLC playback via its HTTP interface.
#
# Reuses a running VLC instance when possible by sending commands through
# the HTTP interface.  Only spawns a new process when VLC is not already
# running.
#
# VLC HTTP interface: http://localhost:VLC_PORT/requests/status.json
#
class VlcPlayer
  VLC_PATH = ENV.fetch('VLC_PATH', '/Applications/VLC.app/Contents/MacOS/VLC')
  VLC_HTTP_PORT = ENV.fetch('VLC_HTTP_PORT', '9090').to_i
  VLC_HTTP_PASSWORD = ENV.fetch('VLC_HTTP_PASSWORD', 'simpsons')

  class << self
    # Play a file in VLC. Reuses the existing instance if one is running,
    # otherwise spawns a new one.
    def play(file_path, start_time: nil)
      if running?
        enqueue_and_play(file_path, start_time: start_time)
      else
        launch(file_path, start_time: start_time)
      end
    end

    # Stop playback (but keep VLC open).
    def stop
      request('?command=pl_stop')
    rescue StandardError
      nil
    end

    # Query VLC's HTTP interface for current playback status.
    # Returns a hash with :state, :time, :length, :position
    def status
      response = request('')
      return nil unless response

      {
        state: response['state'],
        time: response['time']&.to_i || 0,
        length: response['length']&.to_i || 0,
        position: response['position']&.to_f || 0.0
      }
    rescue StandardError => e
      Rails.logger.debug("VlcPlayer: status query failed — #{e.message}")
      nil
    end

    # Check if VLC is currently playing or paused.
    def active?
      s = status
      s && %w[playing paused].include?(s[:state])
    rescue StandardError
      false
    end

    # Check if VLC's HTTP interface is reachable.
    def running?
      status.present?
    rescue StandardError
      false
    end

    private

    # Launch a fresh VLC process with the HTTP interface enabled.
    def launch(file_path, start_time: nil)
      unless File.exist?(VLC_PATH)
        Rails.logger.warn("VlcPlayer: VLC not found at #{VLC_PATH}")
        return nil
      end

      args = [
        VLC_PATH,
        file_path,
        '--extraintf', 'http',
        '--http-port', VLC_HTTP_PORT.to_s,
        '--http-password', VLC_HTTP_PASSWORD,
        '--no-http-forward-cookies',
        '--one-instance'
      ]

      args += ['--start-time', start_time.to_s] if start_time && start_time.to_i > 0

      pid = spawn(*args, %i[out err] => '/dev/null')
      Process.detach(pid)

      Rails.logger.info("VlcPlayer: launched VLC (PID=#{pid}) for #{File.basename(file_path)}")
      pid
    end

    # Tell the running VLC instance to play a new file via the HTTP API.
    # Clears the playlist, adds the new file, and plays it.
    def enqueue_and_play(file_path, start_time: nil)
      encoded_path = URI.encode_www_form_component(file_path)

      # Clear playlist and add the new file
      request('?command=pl_empty')
      request("?command=in_play&input=#{encoded_path}")

      # Wait briefly for VLC to start loading the file, then seek if needed
      if start_time && start_time.to_i > 0
        sleep(0.5)
        request("?command=seek&val=#{start_time.to_i}")
      end

      Rails.logger.info("VlcPlayer: sent #{File.basename(file_path)} to running VLC instance")
      true
    end

    def request(query_path)
      require 'net/http'
      require 'json'

      uri = URI("http://localhost:#{VLC_HTTP_PORT}/requests/status.json#{query_path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = 1
      http.read_timeout = 2

      req = Net::HTTP::Get.new(uri)
      req.basic_auth('', VLC_HTTP_PASSWORD)

      response = http.request(req)
      return nil unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    end
  end
end
