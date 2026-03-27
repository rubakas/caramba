# Manages VLC playback via its HTTP interface.
#
# Launches VLC with --extraintf http and polls status.json to track
# playback position. This only works when the Rails server runs on the
# same machine as VLC (local mode).
#
# VLC HTTP interface: http://localhost:VLC_PORT/requests/status.json
#
class VlcPlayer
  VLC_PATH = ENV.fetch('VLC_PATH', '/Applications/VLC.app/Contents/MacOS/VLC')
  VLC_HTTP_PORT = ENV.fetch('VLC_HTTP_PORT', '9090').to_i
  VLC_HTTP_PASSWORD = ENV.fetch('VLC_HTTP_PASSWORD', 'simpsons')

  class << self
    # Launch VLC with a file, optionally starting at a given position.
    # Returns the PID of the VLC process.
    def play(file_path, start_time: nil)
      unless File.exist?(VLC_PATH)
        Rails.logger.warn("VlcPlayer: VLC not found at #{VLC_PATH}")
        return nil
      end

      # Kill any existing VLC instance we started
      stop

      args = [
        VLC_PATH,
        file_path,
        '--extraintf', 'http',
        '--http-port', VLC_HTTP_PORT.to_s,
        '--http-password', VLC_HTTP_PASSWORD,
        '--no-http-forward-cookies'
      ]

      args += ['--start-time', start_time.to_s] if start_time && start_time > 0

      pid = spawn(*args, %i[out err] => '/dev/null')
      Process.detach(pid)

      Rails.logger.info("VlcPlayer: launched VLC (PID=#{pid}) for #{File.basename(file_path)}")
      pid
    end

    # Stop any running VLC instance by sending a quit command via HTTP.
    def stop
      request('?command=pl_stop')
    rescue StandardError
      nil
    end

    # Query VLC's HTTP interface for current playback status.
    # Returns a hash with :state, :time (seconds), :length (seconds), :position (0.0-1.0)
    def status
      response = request('')
      return nil unless response

      {
        state: response['state'],                    # "playing", "paused", "stopped"
        time: response['time']&.to_i || 0,           # current position in seconds
        length: response['length']&.to_i || 0,       # total duration in seconds
        position: response['position']&.to_f || 0.0  # 0.0 to 1.0
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

    private

    def request(query_path)
      require 'net/http'
      require 'json'

      uri = URI("http://localhost:#{VLC_HTTP_PORT}/requests/status.json#{query_path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = 1
      http.read_timeout = 1

      req = Net::HTTP::Get.new(uri)
      req.basic_auth('', VLC_HTTP_PASSWORD)

      response = http.request(req)
      return nil unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    end
  end
end
