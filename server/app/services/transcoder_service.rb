# Transcoder service — wraps ffmpeg/ffprobe for HLS video streaming.
#
# Output is always HLS with CMAF (fMP4) segments. Every client — Chromium
# desktop/web, Android TV WebView, Safari/iOS — plays from the same manifest.
#
# Three transcoding strategies, chosen per file via ffprobe:
#   1. direct_play — video H.264 + audio AAC: `-c copy`, zero encode CPU
#   2. audio_transcode — video H.264 + non-AAC audio: copy video, re-encode audio
#   3. full_transcode — HEVC or other: VideoToolbox H.264 encode
#
# One active session at a time. Seeking kills ffmpeg and restarts from the
# new position (same behaviour as before). A persistent segment cache is a
# planned follow-up.
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
      args = %w[-v error -print_format json -show_format -show_streams]
      args << file_path

      stdout, stderr, status = run_command(ffprobe_path, args)
      unless status.success?
        raw = stderr.to_s[0..300]
        if raw =~ /Operation not permitted|Permission denied|EPERM|EACCES/i
          raise "macOS blocked reading #{file_path}. " \
                "The process running the Rails server needs Full Disk Access " \
                "(or the terminal launching it does) in System Settings → " \
                "Privacy & Security → Full Disk Access. Alternatively, move the " \
                "media out of ~/Desktop, ~/Documents, or ~/Downloads."
        end
        raise "ffprobe exited with #{status.exitstatus}: #{raw}"
      end

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

    def start_session(session_id, file_path, start_time = 0, opts = {})
      mu = session_mutex(session_id)
      mu.synchronize do
        kill_ffmpeg
        kill_subtitle_extractor
        cleanup_hls_dir

        duration = opts[:duration].to_f
        raise "duration is required" unless duration > 0

        subtitle_stream_index = opts[:subtitle_stream_index]
        is_bitmap = opts[:burn_subtitle_index].present?

        @session = {
          id: session_id,
          file_path: file_path,
          duration: duration,
          seek_time: start_time.to_f,
          audio_stream_index: opts[:audio_stream_index],
          burn_subtitle_index: opts[:burn_subtitle_index],
          subtitle_stream_index: subtitle_stream_index,
          subtitle_vtt: nil,
          hls_dir: File.join(TMP_ROOT, "hls", session_id),
          started_at: Time.current
        }

        start_ffmpeg_hls(file_path, start_time.to_f, opts)

        if subtitle_stream_index && !is_bitmap
          extract_subtitles_async(session_id, file_path, subtitle_stream_index)
        end

        Rails.logger.info "[Transcoder] session #{session_id}: #{File.basename(file_path)}, starting at #{start_time}s"
        session_id
      end
    end

    def seek_session(session_id, seek_time)
      mu = session_mutex(session_id)
      mu.synchronize do
        return nil unless @session && @session[:id] == session_id

        @session[:seek_time] = seek_time.to_f

        cleanup_hls_dir
        start_ffmpeg_hls(
          @session[:file_path],
          seek_time.to_f,
          audio_stream_index: @session[:audio_stream_index],
          burn_subtitle_index: @session[:burn_subtitle_index]
        )

        Rails.logger.info "[Transcoder] seek session #{session_id} to #{seek_time}s"
        seek_time
      end
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
      return nil unless @session && @session[:id] == session_id
      File.join(@session[:hls_dir], "playlist.m3u8")
    end

    # Serve init segment (init.mp4) or media segments (segment_N.m4s).
    # Name is sanitised to prevent directory traversal.
    def hls_asset_path(session_id, asset_name)
      return nil unless @session && @session[:id] == session_id
      safe_name = File.basename(asset_name)
      return nil unless safe_name == "init.mp4" || safe_name.match?(/\Asegment_\d+\.m4s\z/)
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
        Rails.logger.warn "[Subtitle] extraction failed: code=#{status.exitstatus}, stderr=#{stderr.to_s[0..300]}"
        return nil
      end

      stdout
    end

    def extract_subtitles_async(session_id, file_path, stream_index)
      kill_subtitle_extractor

      args = %w[-v quiet]
      args += [ "-i", file_path ]
      args += [ "-map", "0:#{stream_index}" ]
      args += %w[-c:s webvtt -f webvtt pipe:1]

      rd, wr = IO.pipe
      rd.binmode

      pid = spawn(
        ffmpeg_path, *args,
        in: :close,
        out: wr,
        err: :close,
        pgroup: true
      )
      wr.close

      @subtitle_pid = pid
      @subtitle_session_id = session_id
      @subtitle_stream_index = stream_index

      Thread.new do
        begin
          vtt = rd.read
          rd.close
          Process.waitpid(pid, Process::WNOHANG) rescue nil

          if vtt.present? && @session && @session[:id] == session_id
            @session[:subtitle_vtt] = vtt
            @session[:active_subtitle_index] = stream_index
            Rails.logger.info "[Subtitle] Extracted #{vtt.lines.count} lines for stream #{stream_index}"
          end
        rescue IOError, Errno::EPIPE => e
          Rails.logger.debug "[Subtitle] extraction stopped: #{e.class}"
        rescue => e
          Rails.logger.error "[Subtitle] extraction error: #{e.message}"
        ensure
          @subtitle_pid = nil
        end
      end
    end

    def kill_subtitle_extractor
      pid = @subtitle_pid
      @subtitle_pid = nil

      return unless pid

      begin
        Process.kill("TERM", pid)
        Process.waitpid(pid, Process::WNOHANG)
      rescue Errno::ESRCH, Errno::ECHILD
        # already dead
      end
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
    # VTT has absolute timestamps. Shift them so they align with the
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

    def current_seek_time(session_id)
      return 0 unless @session && @session[:id] == session_id
      @session[:seek_time] || 0
    end

    # ── Strategy selection (public for controller/tests) ──────────────

    # Returns one of :direct_play, :audio_transcode, :full_transcode.
    def transcode_strategy(probe_result, audio_stream_index, burn_subtitle_index)
      return :full_transcode if burn_subtitle_index

      video_codec = probe_result.dig(:video, :codec)
      return :full_transcode unless video_codec == "h264"

      audio_stream = (probe_result[:audioStreams] || []).find { |s| s[:index] == audio_stream_index }
      audio_codec = audio_stream ? audio_stream[:codec] : nil

      if audio_codec == "aac"
        :direct_play
      else
        :audio_transcode
      end
    end

    private

    def session_mutex(_session_id = nil)
      @mu ||= Mutex.new
    end

    # ── ffmpeg process management ─────────────────────────────────────

    def kill_ffmpeg
      pid = @ffmpeg_pid
      @ffmpeg_pid = nil

      return unless pid

      begin
        Process.kill("KILL", pid)
      rescue Errno::ESRCH
      end

      begin
        Process.waitpid(pid, Process::WNOHANG)
      rescue Errno::ECHILD
      end
    end

    def stop_inner
      kill_ffmpeg
      kill_subtitle_extractor
      cleanup_hls_dir
      @session = nil
    end

    def cleanup_hls_dir
      return unless @session && @session[:hls_dir]
      FileUtils.rm_rf(@session[:hls_dir]) if Dir.exist?(@session[:hls_dir])
    rescue => e
      Rails.logger.warn "[Transcoder] cleanup_hls_dir error: #{e.message}"
    end

    def start_ffmpeg_hls(file_path, seek_time, opts = {})
      kill_ffmpeg

      hls_dir = @session[:hls_dir]
      FileUtils.mkdir_p(hls_dir)

      probe_result = probe(file_path)
      strategy = transcode_strategy(probe_result, opts[:audio_stream_index], opts[:burn_subtitle_index])

      args = build_hls_ffmpeg_args(file_path, seek_time, hls_dir, strategy, probe_result, opts)

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

      Rails.logger.info "[Transcoder] ffmpeg HLS started: pid=#{pid}, strategy=#{strategy}, seek=#{seek_time}s, dir=#{hls_dir}"
    end

    # ── ffmpeg argument builder ──────────────────────────────────────
    #
    # Single HLS output pipeline. Strategy decides which codec flags to use.
    # CMAF / fMP4 segments (not MPEG-TS): better compatibility with hls.js,
    # native Safari, Android TV WebView, and correct SAR handling out of
    # the box.

    # Resolution-aware bitrate for full_transcode. VideoToolbox H.264 needs
    # meaningfully higher bitrate than x264 to reach the same perceptual quality;
    # at 4 Mbps a 1080p HEVC source transcodes visibly softer than the original.
    # On LAN we have plenty of bandwidth — spend it.
    def full_transcode_video_args(probe_result)
      width = probe_result.dig(:video, :width).to_i
      bitrate, maxrate, bufsize =
        if width >= 3000      then [ "20M", "30M", "60M" ]   # 4K
        elsif width >= 1800   then [ "12M", "18M", "36M" ]   # 1080p
        elsif width >= 1100   then [ "8M",  "12M", "24M" ]   # 720p
        else                       [ "4M",  "6M",  "12M" ]   # SD
        end

      [
        "-c:v", "h264_videotoolbox",
        "-b:v", bitrate,
        "-maxrate", maxrate,
        "-bufsize", bufsize,
        "-profile:v", "high",
        "-pix_fmt", "yuv420p",
        "-g", "48"
      ]
    end

    def build_hls_ffmpeg_args(file_path, seek_time, output_dir, strategy, probe_result, opts = {})
      args = []
      burn_sub = opts[:burn_subtitle_index].present?

      # Hardware decode (macOS VideoToolbox). Skip when burning bitmap
      # subtitles because the overlay filter operates on software frames.
      # Also skip for direct-play (-c copy) since there's no decode path.
      if strategy == :full_transcode && !burn_sub
        args += %w[-hwaccel videotoolbox]
      end

      args += [ "-ss", seek_time.to_s ] if seek_time > 0
      args += %w[-analyzeduration 2000000 -probesize 2000000] if strategy == :full_transcode

      args += [ "-i", file_path ]

      # Filters / stream mapping
      if burn_sub
        args += [ "-filter_complex", "[0:v:0][0:#{opts[:burn_subtitle_index]}]overlay,scale=iw*sar:ih:flags=lanczos,setsar=1" ]
        args += [ "-map", opts[:audio_stream_index] ? "0:#{opts[:audio_stream_index]}" : "0:a:0" ]
      elsif strategy == :full_transcode
        # Anamorphic source handling: enforce square pixels.
        args += [ "-vf", "scale=iw*sar:ih:flags=lanczos,setsar=1" ]
        args += [ "-map", "0:v:0" ]
        args += [ "-map", opts[:audio_stream_index] ? "0:#{opts[:audio_stream_index]}" : "0:a:0" ]
      else
        args += [ "-map", "0:v:0" ]
        args += [ "-map", opts[:audio_stream_index] ? "0:#{opts[:audio_stream_index]}" : "0:a:0" ]
      end

      # Codec selection per strategy
      case strategy
      when :direct_play
        # No re-encode — just remux into CMAF segments.
        args += %w[-c copy]
      when :audio_transcode
        args += %w[-c:v copy]
        args += %w[-c:a aac -b:a 192k -ac 2]
      when :full_transcode
        args += full_transcode_video_args(probe_result)
        args += %w[-c:a aac -b:a 192k -ac 2]
      end

      # HLS output: CMAF (fMP4) segments.
      #   hls_time 2       — 2-second segments so the playlist grows faster than
      #                      playback consumes it, even under 1× realtime encode
      #                      (avoids the "play 4s, stall for 1–3s, resume" pattern).
      #   temp_file        — atomic write: ffmpeg writes *.tmp then renames, so
      #                      the HTTP server never sees a half-flushed segment.
      #   independent_segments — each segment decodes standalone.
      args += %w[
        -f hls
        -hls_time 2
        -hls_list_size 0
        -hls_playlist_type event
        -hls_segment_type fmp4
        -hls_flags independent_segments+append_list+temp_file
        -start_number 0
      ]
      args += [ "-hls_fmp4_init_filename", "init.mp4" ]
      args += [ "-hls_segment_filename", File.join(output_dir, "segment_%d.m4s") ]
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
