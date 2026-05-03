# Transcoder service — wraps ffmpeg/ffprobe for video streaming.
#
# Four strategies, chosen per file via ffprobe (card #55):
#   1. direct_play   — file is browser-playable as-is; no ffmpeg.
#                      Controller serves the original file with HTTP Range.
#   2. direct_stream — codecs OK but container needs remuxing.
#                      ffmpeg `-c copy` → HLS fMP4. Zero encode CPU.
#   3. audio_transcode — video OK, non-AAC audio re-encoded to AAC stereo.
#   4. full_transcode  — re-encode video (VideoToolbox H.264 on macOS).
#
# Transcoded paths (2-4) output HLS with CMAF (fMP4) segments. Every client —
# Chromium desktop/web, Android TV WebView, Safari/iOS — plays from the same
# manifest. The direct_play tier short-circuits this entirely so high-bitrate
# files don't get bottlenecked by realtime encoding or HLS segmentation.
#
# One active session at a time. Seeking kills ffmpeg and restarts from the
# new position. A persistent segment cache is a planned follow-up.
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
      bitrate = data.dig("format", "bit_rate")&.to_i
      # ffprobe joins compatible demuxer names with commas (e.g.
      # "mov,mp4,m4a,3gp,3g2,mj2"). Used by the direct_play strategy to
      # decide whether the browser can demux the source as-is.
      format_name = data.dig("format", "format_name").to_s.downcase

      text_codecs = %w[
        ass ssa srt subrip webvtt mov_text hdmv_text_subtitle
        text ttml microdvd mpl2 pjs realtext sami stl
        subviewer subviewer1 vplayer
      ].freeze

      {
        duration: duration,
        formatName: format_name,
        bitrate: bitrate,
        video: video_stream ? {
          codec: video_stream["codec_name"],
          width: video_stream["width"],
          height: video_stream["height"],
          profile: video_stream["profile"],
          pix_fmt: video_stream["pix_fmt"],
          color_transfer: video_stream["color_transfer"],
          color_primaries: video_stream["color_primaries"],
          color_space: video_stream["color_space"]
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
          codec_support: opts[:codec_support],
          force_transcode: !!opts[:force_transcode],
          strategy: nil,
          started_at: Time.current
        }

        # direct_play short-circuits: pre-compute the strategy from the probe
        # we'd run inside start_ffmpeg_hls anyway, and skip ffmpeg if it's
        # direct_play. Subtitle extraction is still useful, since the file's
        # embedded text subs need to be exposed via the session VTT.
        probe_result = probe(file_path)
        decided = transcode_strategy(
          probe_result,
          opts[:audio_stream_index],
          opts[:burn_subtitle_index],
          opts[:codec_support],
          !!opts[:force_transcode]
        )

        if decided == :direct_play
          @session[:strategy] = :direct_play
        else
          start_ffmpeg_hls(file_path, start_time.to_f, opts.merge(probe_result: probe_result))
        end

        if subtitle_stream_index && !is_bitmap
          extract_subtitles_async(session_id, file_path, subtitle_stream_index)
        end

        Rails.logger.info "[Transcoder] session #{session_id}: #{File.basename(file_path)}, starting at #{start_time}s, strategy=#{@session[:strategy]}"
        { session_id: session_id, strategy: @session[:strategy] }
      end
    end

    def seek_session(session_id, seek_time)
      mu = session_mutex(session_id)
      mu.synchronize do
        return nil unless @session && @session[:id] == session_id

        @session[:seek_time] = seek_time.to_f

        # direct_play has no ffmpeg to restart — the client moves <video>
        # currentTime via the byte-range request. Just record the seek time
        # so subtitle shifting and progress reporting use the right offset.
        if @session[:strategy] == :direct_play
          Rails.logger.info "[Transcoder] direct_play seek session #{session_id} to #{seek_time}s"
          return seek_time
        end

        cleanup_hls_dir
        start_ffmpeg_hls(
          @session[:file_path],
          seek_time.to_f,
          audio_stream_index: @session[:audio_stream_index],
          burn_subtitle_index: @session[:burn_subtitle_index],
          force_transcode: @session[:force_transcode]
        )

        Rails.logger.info "[Transcoder] seek session #{session_id} to #{seek_time}s, strategy=#{@session[:strategy]}"
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

    def direct_play_file_path(session_id)
      return nil unless @session && @session[:id] == session_id
      return nil unless @session[:strategy] == :direct_play
      @session[:file_path]
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

    # Client-supplied MSE codec capabilities trump our fixed list, because
    # MSE HEVC support varies wildly: present on Chromium/macOS and Safari,
    # but often missing in Android WebView (including Android TV WebView on
    # many system images) even when the device can hardware-decode HEVC
    # elsewhere. Fallback defaults assume a modern Chromium desktop — HEVC
    # allowed — which covers Electron and desktop browsers.
    DEFAULT_CLIENT_DIRECT_PLAY_CODECS = %w[h264 hevc h265].freeze

    # Container families a browser <video> can demux directly. ffprobe's
    # format_name is comma-joined (e.g. "mov,mp4,m4a,3gp,3g2,mj2"); we
    # substring-match. MKV/AVI/TS/WebM(*) require remuxing. (* WebM with
    # VP8/VP9 plays direct, but those codecs aren't in the direct-play list.)
    DIRECT_PLAY_CONTAINERS = %w[mp4 m4v mov mj2].freeze

    # 10-bit pixel formats — Chromium MSE on Electron 33 / macOS plays HEVC
    # Main-10 (4K HDR) inconsistently (segments arrive but the decoder
    # produces no frames). Force full_transcode for these.
    TEN_BIT_PIX_FMTS = %w[
      yuv420p10le yuv420p10be
      yuv422p10le yuv422p10be
      yuv444p10le yuv444p10be
      p010le p010be
    ].freeze

    # HDR transfer characteristics — sources tagged with these need an explicit
    # PQ/HLG → linear → BT.709 SDR conversion. Without it, naive 8-bit output
    # crushes mid-tones and produces visible banding on subtle gradients.
    HDR_TRANSFERS = %w[smpte2084 arib-std-b67].freeze

    # zscale + tonemap chain for HDR PQ/HLG → SDR BT.709. Requires libzimg
    # (the `zscale` filter); homebrew ffmpeg without `--enable-libzimg`
    # doesn't have it. Hable curve gives gentle highlight rolloff close to
    # what Jellyfin's web client produces. The float intermediate (gbrpf32le)
    # plus the final yuv420p conversion includes implicit dithering that
    # eliminates the 10→8 bit banding.
    HDR_TONEMAP_CHAIN =
      "zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709," \
      "tonemap=tonemap=hable:desat=0," \
      "zscale=t=bt709:m=bt709:r=tv,format=yuv420p"

    # Output color metadata after tonemapping. Tells the encoder (and the
    # browser decoder) that the stream is BT.709 SDR.
    SDR_OUTPUT_COLOR_FLAGS = %w[
      -color_primaries bt709 -color_trc bt709 -colorspace bt709 -color_range tv
    ].freeze

    def allowed_direct_play_codecs(codec_support)
      return DEFAULT_CLIENT_DIRECT_PLAY_CODECS if codec_support.nil?
      allowed = []
      allowed += %w[h264] if truthy?(codec_support[:h264]) || truthy?(codec_support["h264"])
      allowed += %w[hevc h265] if truthy?(codec_support[:hevc]) || truthy?(codec_support["hevc"])
      # If client reported nothing, assume baseline H.264 (universal).
      allowed.empty? ? %w[h264] : allowed
    end

    def hevc10_supported?(codec_support)
      return false if codec_support.nil?
      truthy?(codec_support[:hevc10]) || truthy?(codec_support["hevc10"])
    end

    # Map ffprobe `codec_name` (lowercase) → key in codec_support[:audio].
    # ffprobe uses "ac3", "eac3", "mp3"; MSE uses "ac-3", "ec-3", "mp3".
    AUDIO_CODEC_PROBE_KEY = {
      "aac"  => :aac,
      "ac3"  => :ac3,
      "eac3" => :eac3,
      "flac" => :flac,
      "mp3"  => :mp3,
      "opus" => :opus
    }.freeze

    # Whether the client can decode this audio codec in an MSE fMP4 segment.
    # AAC is unconditionally allowed (every MSE-capable client supports it,
    # and our segmenter falls back to AAC whenever it can't pass through).
    # Other codecs require an explicit signal in `codec_support[:audio]`.
    def allowed_audio_codec?(codec_name, codec_support)
      return false if codec_name.blank?
      return true if codec_name == "aac"
      return false unless codec_support
      audio_caps = codec_support[:audio] || codec_support["audio"]
      return false unless audio_caps
      key = AUDIO_CODEC_PROBE_KEY[codec_name]
      return false unless key
      truthy?(audio_caps[key]) || truthy?(audio_caps[key.to_s])
    end

    def truthy?(v)
      v == true || v == "true" || v == 1 || v == "1"
    end

    def direct_play_container?(format_name)
      return false if format_name.blank?
      DIRECT_PLAY_CONTAINERS.any? { |c| format_name.include?(c) }
    end

    # Returns one of :direct_play, :direct_stream, :audio_transcode, :full_transcode.
    def transcode_strategy(probe_result, audio_stream_index, burn_subtitle_index, codec_support = nil, force_transcode = false)
      return :full_transcode if burn_subtitle_index
      return :full_transcode if force_transcode

      video_codec = probe_result.dig(:video, :codec)
      allowed = allowed_direct_play_codecs(codec_support)
      return :full_transcode unless allowed.include?(video_codec)

      # 10-bit HEVC: only force re-encode when the client did NOT advertise
      # Main 10 MSE support. Real browsers (Safari, Chrome 107+) decode 10-bit
      # HEVC reliably and report `hevc10: true` — we direct-stream the source
      # so the user gets true HDR with zero re-encode. Electron 33 / Chromium
      # 130 MSE accepts the codec string but stalls on decode, so the http
      # adapter explicitly suppresses hevc10 for the Electron user agent.
      if %w[hevc h265].include?(video_codec) &&
         TEN_BIT_PIX_FMTS.include?(probe_result.dig(:video, :pix_fmt)) &&
         !hevc10_supported?(codec_support)
        return :full_transcode
      end

      audio_stream = (probe_result[:audioStreams] || []).find { |s| s[:index] == audio_stream_index }
      audio_codec = audio_stream ? audio_stream[:codec] : nil

      return :audio_transcode unless allowed_audio_codec?(audio_codec, codec_support)

      # Codecs are compatible. If the container is also browser-friendly,
      # serve the file as-is (direct_play, no ffmpeg). Otherwise remux into
      # fMP4 via `-c copy` (direct_stream).
      if direct_play_container?(probe_result[:formatName])
        :direct_play
      else
        :direct_stream
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
      Sentry.capture_exception(e, tags: { subsystem: "transcoder" }) if defined?(Sentry) && Sentry.initialized?
      Rails.logger.warn "[Transcoder] cleanup_hls_dir error: #{e.message}"
    end

    def start_ffmpeg_hls(file_path, seek_time, opts = {})
      kill_ffmpeg

      hls_dir = @session[:hls_dir]
      FileUtils.mkdir_p(hls_dir)

      probe_result = opts[:probe_result] || probe(file_path)
      codec_support = @session && @session[:codec_support]
      force_transcode = (opts.key?(:force_transcode) ? opts[:force_transcode] : @session && @session[:force_transcode]) ? true : false
      strategy = transcode_strategy(probe_result, opts[:audio_stream_index], opts[:burn_subtitle_index], codec_support, force_transcode)

      @session[:strategy] = strategy if @session

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

      vf = extract_arg(args, "-vf") || extract_arg(args, "-filter_complex")
      bv = extract_arg(args, "-b:v")
      ba = extract_arg(args, "-b:a")
      ac = extract_arg(args, "-ac")
      Rails.logger.info "[Transcoder] ffmpeg HLS started: pid=#{pid}, strategy=#{strategy}, " \
        "seek=#{seek_time}s, video=#{bv ? "#{(bv.to_i / 1_000_000.0).round(1)}M" : "copy"}, " \
        "audio=#{ba || 'copy'}#{ac ? "/#{ac}ch" : ''}, hdr_filter=#{vf && vf.include?('tonemap') ? 'tonemap' : 'none'}"
      Rails.logger.debug "[Transcoder] -vf: #{vf}" if vf
    end

    # Extract the value following a flag from a flat ffmpeg arg array.
    def extract_arg(args, flag)
      idx = args.index(flag)
      idx && args[idx + 1]
    end

    # ── ffmpeg argument builder ──────────────────────────────────────
    #
    # Single HLS output pipeline. Strategy decides which codec flags to use.
    # CMAF / fMP4 segments (not MPEG-TS): better compatibility with hls.js,
    # native Safari, Android TV WebView, and correct SAR handling out of
    # the box.

    # True when the source is HDR-graded (PQ or HLG). Drives the tonemap
    # branch in the filter chain. Kept tolerant of probe shape differences
    # (TechProbeService caches symbolize on read; live probe uses symbols).
    def hdr_source?(probe_result)
      transfer = probe_result.dig(:video, :color_transfer).to_s
      HDR_TRANSFERS.include?(transfer)
    end

    # Whether the resolved ffmpeg binary has the `zscale` filter compiled in.
    # Memoized per process — `ffmpeg -filters` is ~30ms. The flag column in
    # `ffmpeg -filters` output is 2-3 chars wide ([T.][S.][C.]), so we just
    # match a token boundary around the filter name rather than pinning the
    # exact flags.
    def zscale_available?
      return @zscale_available unless @zscale_available.nil?
      stdout, _stderr, status = Open3.capture3(ffmpeg_path, "-hide_banner", "-filters")
      @zscale_available = status.success? && stdout.match?(/^\s+\S+\s+zscale\s+/)
    rescue StandardError
      @zscale_available = false
    end

    # AAC encode args sized to the source channel layout. Browsers decode
    # AAC-LC up to 5.1 reliably; 7.1 is inconsistent across MSE
    # implementations, so we cap at 6 channels (downmixing 7.1 → 5.1, never
    # to stereo). Bitrate scales with channel count so 5.1 sources don't get
    # squashed into a 192k stereo-grade allocation.
    def audio_transcode_args(probe_result, audio_stream_index)
      stream = (probe_result[:audioStreams] || []).find { |s| s[:index] == audio_stream_index }
      source_channels = stream && stream[:channels].to_i > 0 ? stream[:channels].to_i : 2
      channels = [ source_channels, 6 ].min
      bitrate =
        if channels >= 6 then "384k"
        elsif channels >= 3 then "256k"
        else                     "192k"
        end

      args = [ "-c:a", "aac", "-b:a", bitrate ]
      # Only force a layout change when we're capping 7.1 → 5.1; for matching
      # or smaller layouts, let ffmpeg preserve the source channel order.
      args += [ "-ac", channels.to_s ] if source_channels > channels
      # Force the AAC sample rate to match the source. With 7.1 → 5.1 downmix
      # ffmpeg occasionally picks an off-by-one rate that drifts audio.
      args += [ "-ar", "48000" ]
      # Sample-level alignment of the re-encoded audio. Conservative async=1
      # (1 sample/sec compensation) — combined with the -copyts family at the
      # input level, this is enough; aggressive async values caused over-
      # compensation and audible drift on TrueHD/DTS-HD MA decoding paths.
      args += [ "-af", "aresample=async=1" ]
      args
    end

    # Per-resolution bitrate ceilings for full_transcode. VideoToolbox H.264
    # needs meaningfully higher bitrate than x264 to reach the same perceptual
    # quality, so we set ceilings high enough that the typical case is "match
    # the source." On LAN we have plenty of bandwidth.
    #
    # Caps in bits/sec: 4K 40M, 1080p 20M, 720p 12M, SD 6M.
    def video_bitrate_cap_bps(width)
      if width >= 3000      then 40_000_000
      elsif width >= 1800   then 20_000_000
      elsif width >= 1100   then 12_000_000
      else                       6_000_000
      end
    end

    # Source-aware bitrate selection. Reads probe :bitrate (set by both
    # TechProbeService and TranscoderService.probe). Targets the source's
    # bitrate so the output is perceptually close to the original, capped
    # per resolution so a 100 Mbps remux doesn't blow up encoding.
    # Falls back to the cap when the probe didn't provide a bitrate.
    def full_transcode_video_args(probe_result)
      width  = probe_result.dig(:video, :width).to_i
      cap    = video_bitrate_cap_bps(width)
      source = probe_result[:bitrate].to_i
      target = source > 0 ? [ source, cap ].min : cap
      maxrate = (target * 1.5).round
      bufsize = (target * 3).round

      [
        "-c:v", "h264_videotoolbox",
        "-allow_sw", "1",
        "-b:v", target.to_s,
        "-maxrate", maxrate.to_s,
        "-bufsize", bufsize.to_s,
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

      hdr = hdr_source?(probe_result)
      tonemap = hdr && zscale_available?
      width = probe_result.dig(:video, :width).to_i

      # Filters / stream mapping. SAR fix is always applied. For tonemapped
      # HDR sources wider than 1080p we downscale BEFORE the zscale/tonemap
      # chain — that's where the CPU goes (zscale + tonemap operate on every
      # pixel in linear-light float space; 4K → 1080p is ~4× less work) and
      # the output is 8-bit SDR anyway so the extra resolution would only
      # serve to inflate the encode bitrate.
      base_filter = "scale=iw*sar:ih:flags=lanczos,setsar=1"
      base_filter += ",scale=-2:1080:flags=lanczos" if tonemap && width >= 2560
      base_filter += ",#{HDR_TONEMAP_CHAIN}" if tonemap

      if burn_sub
        chain = "[0:v:0][0:#{opts[:burn_subtitle_index]}]overlay,#{base_filter}"
        args += [ "-filter_complex", chain ]
        args += [ "-map", opts[:audio_stream_index] ? "0:#{opts[:audio_stream_index]}" : "0:a:0" ]
      elsif strategy == :full_transcode
        if hdr && !zscale_available?
          Rails.logger.warn "[Transcoder] HDR source but ffmpeg lacks zscale — output will band. Install ffmpeg with libzimg or use the vendored binary."
        end
        args += [ "-vf", base_filter ]
        args += [ "-map", "0:v:0" ]
        args += [ "-map", opts[:audio_stream_index] ? "0:#{opts[:audio_stream_index]}" : "0:a:0" ]
      else
        args += [ "-map", "0:v:0" ]
        args += [ "-map", opts[:audio_stream_index] ? "0:#{opts[:audio_stream_index]}" : "0:a:0" ]
      end

      # Codec selection per strategy
      case strategy
      when :direct_stream
        # No re-encode — just remux into CMAF segments.
        args += %w[-c copy]
      when :audio_transcode
        args += %w[-c:v copy]
        args += audio_transcode_args(probe_result, opts[:audio_stream_index])
      when :full_transcode
        args += full_transcode_video_args(probe_result)
        # When tonemapping HDR → SDR, tag the output with BT.709 metadata so
        # the browser decoder interprets the colorspace correctly. Without
        # these the decoder may apply its own legacy conversion on top.
        args += SDR_OUTPUT_COLOR_FLAGS if hdr && zscale_available?
        args += audio_transcode_args(probe_result, opts[:audio_stream_index])
      end
      # :direct_play is unreachable here — start_session short-circuits before
      # calling start_ffmpeg_hls when the strategy resolves to direct_play.

      # (We tested `-tag:v hvc1` for HEVC copy paths — counter-intuitively,
      # that retag broke playback on Electron 33 / Chromium 130 / macOS for
      # HEVC Main-10 sources: readyState went to 4 with currentTime stuck.
      # ffmpeg's default `hev1` tag plays correctly on this stack via
      # VideoToolbox. Mirrored on the desktop side.)

      # HLS output: CMAF (fMP4) segments.
      #   hls_time 6       — 6-second segments matches Jellyfin's default and
      #                      reduces HTTP round-trips. VideoToolbox H.264
      #                      encodes well above 1× realtime on Apple Silicon
      #                      (4K ≥ 4×, 1080p ≥ 10×) so segment production
      #                      stays well ahead of playback consumption.
      #   temp_file        — atomic write: ffmpeg writes *.tmp then renames, so
      #                      the HTTP server never sees a half-flushed segment.
      #   independent_segments — each segment decodes standalone.
      args += %w[
        -f hls
        -hls_time 6
        -hls_list_size 0
        -hls_playlist_type event
        -hls_segment_type fmp4
        -hls_flags independent_segments+temp_file
        -start_number 0
      ]
      args += [ "-hls_fmp4_init_filename", "init.mp4" ]
      args += [ "-hls_segment_filename", File.join(output_dir, "segment_%d.m4s") ]
      args += [ File.join(output_dir, "playlist.m3u8") ]

      args += %w[-y -nostdin]

      args
    end

    # ── Utility ──────────────────────────────────────────────────────

    # Prefer the vendored ffmpeg shared with the desktop app (compiled with
    # libzimg, so the `zscale` filter is available — required by the HDR
    # tonemap chain). The vendored path resolves only in dev where the repo
    # is laid out as ../desktop/vendor; in any deployment without that
    # directory, falls through to system ffmpeg.
    def find_binary(name)
      vendored = File.expand_path("../../../desktop/vendor/ffmpeg-arm64/#{name}", __dir__)
      return vendored if File.executable?(vendored)

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
