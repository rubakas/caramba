# Transcoder service — wraps ffmpeg/ffprobe for video streaming.
#
# Architecture:
# - fMP4 mode: Direct pipe to HTTP response via ActionController::Live (MSE clients)
# - HLS mode: Outputs .m3u8 playlist + .ts segments to temp directory (Safari/iOS)
#
# Seeking kills the ffmpeg process and starts a new one from the target
# position. The client gets a new stream URL and re-sets video.src.
#
# One active session at a time (singleton, like desktop).
class TranscoderService
  TMP_ROOT = File.join(Dir.tmpdir, "caramba-sessions")

  class << self
    # ── Binary discovery ──────────────────────────────────────────────

    def ffmpeg_path
      @ffmpeg_path ||= find_binary("ffmpeg")
    end

    def ffprobe_path
      @ffprobe_path ||= find_binary("ffprobe")
    end

    # ── Probe ─────────────────────────────────────────────────────────

    def probe(file_path)
      args = %w[-v quiet -print_format json -show_format -show_streams]
      args << file_path

      stdout, stderr, status = run_command(ffprobe_path, args)
      raise "ffprobe exited with #{status.exitstatus}: #{stderr[0..300]}" unless status.success?

      data = JSON.parse(stdout)
      video_stream = (data["streams"] || []).find { |s| s["codec_type"] == "video" && s["codec_name"] != "mjpeg" }
      audio_streams = (data["streams"] || []).select { |s| s["codec_type"] == "audio" }
      subtitle_streams = (data["streams"] || []).select { |s| s["codec_type"] == "subtitle" }
      duration = data.dig("format", "duration").to_f

      text_codecs = %w[
        ass ssa srt subrip webvtt mov_text hdmv_text_subtitle
        text ttml microdvd mpl2 pjs realtext sami stl
        subviewer subviewer1 vplayer
      ].freeze

      {
        duration: duration,
        video: video_stream ? {
          codec: video_stream["codec_name"],
          width: video_stream["width"],
          height: video_stream["height"],
          profile: video_stream["profile"],
          pix_fmt: video_stream["pix_fmt"]
        } : nil,
        audioStreams: audio_streams.map { |s|
          {
            index: s["index"],
            codec: s["codec_name"],
            channels: s["channels"],
            language: s.dig("tags", "language") || "und",
            title: s.dig("tags", "title")
          }
        },
        subtitleStreams: subtitle_streams.map { |s|
          {
            index: s["index"],
            codec: s["codec_name"],
            language: s.dig("tags", "language") || "und",
            title: s.dig("tags", "title"),
            isText: text_codecs.include?(s["codec_name"])
          }
        }
      }
    end

    # ── Session management ────────────────────────────────────────────

    # Start (or restart) a session.  Kills any existing ffmpeg process,
    # spawns a new one, and stores session metadata.
    #
    # Does NOT block waiting for output — the controller's stream action
    # will read from the ffmpeg stdout pipe.
    #
    # @param opts[:format] - :fmp4 (default) or :hls
    def start_session(session_id, file_path, start_time = 0, opts = {})
      mu = session_mutex(session_id)
      mu.synchronize do
        kill_ffmpeg
        cleanup_hls_dir  # clean up any previous HLS segments

        duration = opts[:duration].to_f
        raise "duration is required" unless duration > 0

        format = opts[:format]&.to_sym || :fmp4

        @session = {
          id: session_id,
          file_path: file_path,
          duration: duration,
          seek_time: start_time.to_f,
          audio_stream_index: opts[:audio_stream_index],
          burn_subtitle_index: opts[:burn_subtitle_index],
          subtitle_vtt: nil,
          format: format,
          hls_dir: format == :hls ? File.join(TMP_ROOT, "hls", session_id) : nil,
          started_at: Time.current
        }

        if format == :hls
          start_ffmpeg_hls(file_path, start_time.to_f, opts)
        else
          start_ffmpeg(file_path, start_time.to_f, opts)
        end

        Rails.logger.info "[Transcoder] session #{session_id} (#{format}): #{File.basename(file_path)}, " \
          "starting at #{start_time}s"
        session_id
      end
    end

    # Seek: kill ffmpeg and restart from a new position.
    # Returns the new seek time.
    def seek_session(session_id, seek_time)
      mu = session_mutex(session_id)
      mu.synchronize do
        return nil unless @session && @session[:id] == session_id

        @session[:seek_time] = seek_time.to_f

        if @session[:format] == :hls
          cleanup_hls_dir  # remove old segments before restarting
          start_ffmpeg_hls(
            @session[:file_path],
            seek_time.to_f,
            audio_stream_index: @session[:audio_stream_index],
            burn_subtitle_index: @session[:burn_subtitle_index]
          )
        else
          start_ffmpeg(
            @session[:file_path],
            seek_time.to_f,
            audio_stream_index: @session[:audio_stream_index],
            burn_subtitle_index: @session[:burn_subtitle_index]
          )
        end

        Rails.logger.info "[Transcoder] seek session #{session_id} to #{seek_time}s"
        seek_time
      end
    end

    # Get the ffmpeg stdout IO for streaming to the client.
    # Returns nil if no active session.
    def stream_io
      return nil unless @ffmpeg_pid && @ffmpeg_stdout
      @ffmpeg_stdout
    end

    def stop_session(session_id)
      mu = session_mutex(session_id)
      mu.synchronize do
        return unless @session && @session[:id] == session_id
        stop_inner
        Rails.logger.info "[Transcoder] stopped session #{session_id}"
      end
    end

    def stop_all
      stop_inner
    end

    # ── HLS file accessors ────────────────────────────────────────────

    def hls_playlist_path(session_id)
      return nil unless @session && @session[:id] == session_id && @session[:format] == :hls
      File.join(@session[:hls_dir], "playlist.m3u8")
    end

    def hls_segment_path(session_id, segment_name)
      return nil unless @session && @session[:id] == session_id && @session[:format] == :hls
      # Sanitize segment name to prevent directory traversal
      safe_name = File.basename(segment_name)
      return nil unless safe_name.match?(/\Asegment_\d+\.ts\z/)
      File.join(@session[:hls_dir], safe_name)
    end

    def hls_dir(session_id)
      return nil unless @session && @session[:id] == session_id
      @session[:hls_dir]
    end

    # ── Subtitle extraction ───────────────────────────────────────────

    def extract_subtitles(file_path, stream_index)
      args = %w[-v quiet]
      args += [ "-i", file_path ]
      args += [ "-map", "0:#{stream_index}" ]
      args += %w[-c:s webvtt -f webvtt pipe:1]

      stdout, stderr, status = run_command(ffmpeg_path, args)
      unless status.success? && stdout.present?
        Rails.logger.warn "[Subtitle] extraction failed: code=#{status.exitstatus}, stderr=#{stderr[0..300]}"
        return nil
      end

      stdout
    end

    def set_session_subtitle(session_id, vtt, stream_index: nil)
      return unless @session && @session[:id] == session_id
      @session[:subtitle_vtt] = vtt
      @session[:active_subtitle_index] = stream_index if stream_index
      @session[:active_subtitle_index] = nil if vtt.nil? && stream_index.nil?
    end

    def get_session_subtitle(session_id)
      return nil unless @session && @session[:id] == session_id
      @session[:subtitle_vtt]
    end

    # ── Session info ──────────────────────────────────────────────────

    def active?(session_id)
      @session && @session[:id] == session_id
    end

    def ffmpeg_running?
      return false unless @ffmpeg_pid
      begin
        Process.kill(0, @ffmpeg_pid)
        true
      rescue Errno::ESRCH
        false
      end
    end

    def session_info(session_id)
      return nil unless @session && @session[:id] == session_id
      @session
    end

    # ── VTT timestamp shifting ────────────────────────────────────────
    #
    # After a seek, video.currentTime restarts from 0 but the extracted
    # VTT has absolute timestamps.  Shift them so they align with the
    # video element's relative timeline.

    def shift_vtt(vtt, offset)
      return vtt if offset <= 0 || vtt.blank?

      time_line_re = /^(\d{1,2}:(?:\d{2}:)?\d{2}\.\d{3})\s*-->\s*(\d{1,2}:(?:\d{2}:)?\d{2}\.\d{3})(.*)/
      lines = vtt.split("\n")
      result = []
      skip_cue = false

      lines.each do |line|
        match = line.match(time_line_re)
        if match
          start_time = parse_vtt_time(match[1]) - offset
          end_time = parse_vtt_time(match[2]) - offset

          if end_time <= 0
            skip_cue = true
            next
          end

          start_time = 0 if start_time < 0
          skip_cue = false
          result << "#{format_vtt_time(start_time)} --> #{format_vtt_time(end_time)}#{match[3]}"
        elsif skip_cue
          skip_cue = false if line.strip.empty?
        else
          result << line
        end
      end

      result.join("\n")
    end

    # Current seek base for subtitle shifting
    def current_seek_time(session_id)
      return 0 unless @session && @session[:id] == session_id
      @session[:seek_time] || 0
    end

    private

    def session_mutex(_session_id = nil)
      @mu ||= Mutex.new
    end

    # ── ffmpeg process management ─────────────────────────────────────

    def start_ffmpeg(file_path, seek_time, opts = {})
      kill_ffmpeg  # kill any existing process (preserves @session)

      args = build_ffmpeg_args(file_path, seek_time, opts)

      # Spawn ffmpeg with stdout as a pipe (for streaming to client)
      # and stderr going to a log file for debugging.
      log_dir = File.join(TMP_ROOT, "logs")
      FileUtils.mkdir_p(log_dir)
      stderr_log = File.open(File.join(log_dir, "ffmpeg_stderr.log"), "w")

      rd, wr = IO.pipe
      rd.binmode

      pid = spawn(
        ffmpeg_path, *args,
        in: :close,
        out: wr,
        err: stderr_log,
        pgroup: true
      )

      wr.close          # parent doesn't write
      stderr_log.close   # let the child own it

      @ffmpeg_pid = pid
      @ffmpeg_stdout = rd
      @ffmpeg_stderr_log = stderr_log

      Rails.logger.info "[Transcoder] ffmpeg started: pid=#{pid}, seek=#{seek_time}s"
    end

    # Kill the ffmpeg process and close the IO pipe.
    # Does NOT clear @session — that's the caller's responsibility.
    def kill_ffmpeg
      pid = @ffmpeg_pid
      stdout = @ffmpeg_stdout

      @ffmpeg_pid = nil
      @ffmpeg_stdout = nil

      if stdout
        stdout.close rescue nil
      end

      return unless pid

      begin
        Process.kill("KILL", pid)
      rescue Errno::ESRCH
        # already dead
      end

      begin
        Process.waitpid(pid, Process::WNOHANG)
      rescue Errno::ECHILD
        # already reaped
      end
    end

    # Full stop: kill ffmpeg and clear session state.
    def stop_inner
      kill_ffmpeg
      cleanup_hls_dir
      @session = nil
    end

    # Clean up HLS segment directory
    def cleanup_hls_dir
      return unless @session && @session[:hls_dir]
      FileUtils.rm_rf(@session[:hls_dir]) if Dir.exist?(@session[:hls_dir])
    rescue => e
      Rails.logger.warn "[Transcoder] cleanup_hls_dir error: #{e.message}"
    end

    # ── HLS ffmpeg spawner ───────────────────────────────────────────

    def start_ffmpeg_hls(file_path, seek_time, opts = {})
      kill_ffmpeg  # kill any existing process

      hls_dir = @session[:hls_dir]
      FileUtils.mkdir_p(hls_dir)

      args = build_hls_ffmpeg_args(file_path, seek_time, hls_dir, opts)

      # Spawn ffmpeg outputting to HLS files (not stdout)
      log_dir = File.join(TMP_ROOT, "logs")
      FileUtils.mkdir_p(log_dir)
      stderr_log = File.open(File.join(log_dir, "ffmpeg_hls_stderr.log"), "w")

      pid = spawn(
        ffmpeg_path, *args,
        in: :close,
        out: :close,
        err: stderr_log,
        pgroup: true
      )

      stderr_log.close

      @ffmpeg_pid = pid
      @ffmpeg_stdout = nil  # HLS mode doesn't use stdout pipe

      Rails.logger.info "[Transcoder] ffmpeg HLS started: pid=#{pid}, seek=#{seek_time}s, dir=#{hls_dir}"
    end

    # ── ffmpeg argument builder ──────────────────────────────────────
    #
    # Mirrors desktop/electron/services/transcoder.js exactly:
    # H.264 via VideoToolbox + AAC → fragmented MP4 on stdout.

    def build_ffmpeg_args(file_path, seek_time, opts = {})
      args = []
      burn_sub = opts[:burn_subtitle_index].present?

      # Hardware-accelerated decoding (VideoToolbox).
      # When burning bitmap subtitles we need the overlay filter which
      # operates on software frames, so skip hwaccel.
      args += %w[-hwaccel videotoolbox] unless burn_sub

      # Seek before input for fast seeking
      args += [ "-ss", seek_time.to_s ] if seek_time > 0

      # No readrate throttle: let ffmpeg transcode as fast as the hardware
      # encoder allows. The client's MSE SourceBuffer handles flow control.

      args += [ "-i", file_path ]

      if burn_sub
        args += [ "-filter_complex", "[0:v:0][0:#{opts[:burn_subtitle_index]}]overlay" ]
        if opts[:audio_stream_index]
          args += [ "-map", "0:#{opts[:audio_stream_index]}" ]
        else
          args += [ "-map", "0:a:0" ]
        end
      else
        args += [ "-map", "0:v:0" ]
        if opts[:audio_stream_index]
          args += [ "-map", "0:#{opts[:audio_stream_index]}" ]
        else
          args += [ "-map", "0:a:0" ]
        end
      end

      # Video encoding: H.264 via VideoToolbox (matches desktop)
      # -g 48 = keyframe every 2s at 24fps. Without this, VideoToolbox
      # inserts keyframes every ~0.5s which fragments the MP4 excessively.
      args += %w[
        -c:v h264_videotoolbox
        -b:v 4M
        -maxrate 6M
        -bufsize 12M
        -profile:v high
        -pix_fmt yuv420p
        -g 48
      ]

      # Audio: AAC stereo
      args += %w[-c:a aac -b:a 192k -ac 2]

      # Output: fragmented MP4 to stdout.
      # empty_moov: no samples in the initial moov (required for streaming)
      # default_base_moof: each moof is self-contained (required for MSE/fMP4)
      # frag_keyframe: start a new fragment at each keyframe
      args += %w[
        -f mp4
        -movflags frag_keyframe+empty_moov+default_base_moof
        pipe:1
      ]

      args += %w[-y -nostdin]

      args
    end

    # ── HLS ffmpeg argument builder ──────────────────────────────────
    #
    # Outputs HLS playlist + TS segments for Safari/iOS compatibility.

    def build_hls_ffmpeg_args(file_path, seek_time, output_dir, opts = {})
      args = []
      burn_sub = opts[:burn_subtitle_index].present?

      # Hardware-accelerated decoding (VideoToolbox)
      args += %w[-hwaccel videotoolbox] unless burn_sub

      # Seek before input for fast seeking
      args += [ "-ss", seek_time.to_s ] if seek_time > 0

      args += [ "-i", file_path ]

      # Apply video filter to handle SAR (Sample Aspect Ratio).
      # MPEG-TS doesn't carry SAR correctly, causing anamorphic sources to
      # display stretched. We scale to square pixels: width * SAR, then set SAR=1.
      # The scale filter uses -2 for height to ensure even dimensions (required by h264).
      if burn_sub
        # Burn subtitles + fix SAR
        args += [ "-filter_complex", "[0:v:0][0:#{opts[:burn_subtitle_index]}]overlay,scale=iw*sar:ih:flags=lanczos,setsar=1" ]
        if opts[:audio_stream_index]
          args += [ "-map", "0:#{opts[:audio_stream_index]}" ]
        else
          args += [ "-map", "0:a:0" ]
        end
      else
        # Scale to square pixels for anamorphic sources
        args += [ "-vf", "scale=iw*sar:ih:flags=lanczos,setsar=1" ]
        args += [ "-map", "0:v:0" ]
        if opts[:audio_stream_index]
          args += [ "-map", "0:#{opts[:audio_stream_index]}" ]
        else
          args += [ "-map", "0:a:0" ]
        end
      end

      # Video encoding: H.264 via VideoToolbox
      args += %w[
        -c:v h264_videotoolbox
        -b:v 4M
        -maxrate 6M
        -bufsize 12M
        -profile:v high
        -pix_fmt yuv420p
        -g 48
      ]

      # Audio: AAC stereo
      args += %w[-c:a aac -b:a 192k -ac 2]

      # HLS output settings
      # -hls_time 4: 4-second segments (reduces request frequency)
      # -hls_list_size 0: VOD-style playlist keeps all segments (required for seeking)
      # -hls_playlist_type event: playlist grows as segments are added
      # -start_number 0: segment numbering starts at 0
      # -output_ts_offset: reset timestamps so HLS starts at 0 (even after -ss seek)
      args += %w[
        -f hls
        -hls_time 4
        -hls_list_size 0
        -hls_playlist_type event
        -hls_segment_type mpegts
        -start_number 0
      ]
      # Reset output timestamps to 0 when seeking
      args += %w[-output_ts_offset 0] if seek_time > 0
      args += [ "-hls_segment_filename", File.join(output_dir, "segment_%d.ts") ]
      args += [ File.join(output_dir, "playlist.m3u8") ]

      args += %w[-y -nostdin]

      args
    end

    # ── Utility ──────────────────────────────────────────────────────

    def find_binary(name)
      candidates = [
        "/opt/homebrew/bin/#{name}",
        "/usr/local/bin/#{name}",
        "/usr/bin/#{name}"
      ]

      candidates.each { |p| return p if File.executable?(p) }

      path = `which #{name} 2>/dev/null`.strip
      return path if path.present? && File.executable?(path)

      raise "#{name} not found. Install via: brew install ffmpeg"
    end

    def run_command(binary, args)
      require "open3"
      Open3.capture3(binary, *args)
    end

    def parse_vtt_time(str)
      parts = str.split(":")
      if parts.length == 3
        hours, minutes, rest = parts
      else
        hours = 0
        minutes, rest = parts
      end
      seconds, millis = rest.split(".")
      hours.to_f * 3600 + minutes.to_f * 60 + seconds.to_f + (millis || "0").to_f / 1000
    end

    def format_vtt_time(seconds)
      seconds = [ seconds, 0 ].max
      h = (seconds / 3600).floor
      m = ((seconds % 3600) / 60).floor
      s = (seconds % 60).floor
      ms = ((seconds * 1000) % 1000).round
      format("%02d:%02d:%02d.%03d", h, m, s, ms)
    end
  end
end
