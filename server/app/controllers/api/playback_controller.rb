class Api::PlaybackController < Api::BaseController
  # ── Existing endpoints ──────────────────────────────────────────────

  # POST /api/playback/report_progress
  def report_progress
    time = params[:time].to_i
    duration = params[:duration].to_i
    return head(:unprocessable_entity) if duration <= 0

    if params[:episode_id].present?
      ep = Episode.find(params[:episode_id])
      ep.update_progress!(time, duration)

      if params[:watch_history_id].present?
        wh = WatchHistory.find(params[:watch_history_id])
        wh.update_progress!(time, duration)
      end

      ep.mark_watched! if time.to_f / duration >= Watchable::WATCHED_THRESHOLD
    end

    if params[:movie_id].present?
      movie = Movie.find(params[:movie_id])
      movie.update_progress!(time, duration)
      movie.mark_watched! if time.to_f / duration >= Watchable::WATCHED_THRESHOLD
    end

    render json: { absoluteTime: time, duration: duration }
  end

  # GET /api/playback/preferences?type=episode&show_id=1 or ?type=movie&movie_id=1
  def preferences
    pref = find_preference
    return render(json: nil) unless pref

    render json: {
      audioLanguage: pref.audio_language,
      audioCodec: pref.audio_codec,
      audioChannels: pref.audio_channels,
      subtitleLanguage: pref.subtitle_language,
      subtitleOff: pref.subtitle_off != 0,
      subtitleSize: pref.subtitle_size || "medium",
      subtitleStyle: pref.subtitle_style || "classic"
    }
  end

  # POST /api/playback/preferences
  def save_preferences
    if params[:type] == "episode" && params[:showId].present?
      pref = PlaybackPreference.find_or_initialize_by(show_id: params[:showId])
      pref.update!(preference_attrs)
    elsif params[:type] == "movie" && params[:movieId].present?
      pref = PlaybackPreference.find_or_initialize_by(movie_id: params[:movieId])
      pref.update!(preference_attrs)
    end

    render json: true
  end

  # ── Streaming endpoints ─────────────────────────────────────────────

  # POST /api/playback/start
  # Body: { filePath, startTime, prefs, codecSupport: { h264, hevc }, forceTranscode }
  # Returns: { hlsUrl, sessionId, duration, startTime, seekBase, strategy, ... }
  def start
    file_path = params[:filePath]
    start_time = (params[:startTime] || 0).to_f
    prefs = params[:prefs]
    codec_support = params[:codecSupport] # { h264: bool, hevc: bool }
    force_transcode = ActiveModel::Type::Boolean.new.cast(params[:forceTranscode])

    return render(json: { error: "filePath required" }, status: :unprocessable_entity) unless file_path.present?
    return render(json: { error: "File not found: #{file_path}" }, status: :unprocessable_entity) unless File.exist?(file_path)

    # Prefer cached probe data on the Episode/Movie row (written at scan
    # time by TechProbeJob). Falls back to a live ffprobe when missing.
    record = find_record_for(file_path)
    info = (record && TechProbeService.probe_for(record)) || TranscoderService.probe(file_path)

    audio_stream_index = select_audio_track(info[:audioStreams], prefs, codec_support)
    subtitle_stream_index, is_bitmap = select_subtitle_track(info[:subtitleStreams], prefs)

    session_id = SecureRandom.hex(8)

    result = TranscoderService.start_session(session_id, file_path, start_time,
      audio_stream_index: audio_stream_index,
      burn_subtitle_index: is_bitmap ? subtitle_stream_index : nil,
      subtitle_stream_index: subtitle_stream_index,
      duration: info[:duration],
      codec_support: codec_support,
      force_transcode: force_transcode)

    session[:playback_session_id] = session_id

    is_direct_play = result[:strategy] == :direct_play
    stream_url =
      if is_direct_play
        "#{api_base_url}/api/playback/file/#{session_id}"
      else
        "#{api_base_url}/api/playback/hls/#{session_id}/playlist.m3u8"
      end
    subtitle_url = subtitle_stream_index && !is_bitmap ? "#{api_base_url}/api/playback/subtitles?session=#{session_id}" : nil

    render json: {
      # `hlsUrl` historically named the manifest URL; for direct_play it's
      # actually a file URL. The renderer reads strategy and routes the
      # element accordingly.
      hlsUrl: stream_url,
      streamUrl: stream_url,
      sessionId: session_id,
      duration: info[:duration],
      startTime: start_time,
      # direct_play: <video>.currentTime is absolute, so seekBase is 0.
      # For ffmpeg-fed strategies seekBase tracks the -ss offset.
      seekBase: is_direct_play ? 0 : start_time,
      subtitleUrl: subtitle_url,
      video: info[:video],
      bitrate: info[:bitrate],
      audioStreams: info[:audioStreams],
      subtitleStreams: info[:subtitleStreams],
      activeAudioIndex: audio_stream_index,
      activeSubtitleIndex: subtitle_stream_index,
      isBitmapSubtitle: is_bitmap,
      strategy: result[:strategy].to_s
    }
  rescue => e
    Rails.logger.error "[Playback] start error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    render json: { error: e.message }, status: :internal_server_error
  end

  # POST /api/playback/seek
  # Body: { session, seekTime }
  #
  # Kills ffmpeg and restarts at the target time. Returns the new HLS URL
  # (cache-busted) for the client to reload.
  def seek
    session_id = params[:session]
    seek_time = params[:seekTime].to_f

    info = TranscoderService.session_info(session_id)
    return render(json: { error: "No active session" }, status: :not_found) unless info

    TranscoderService.seek_session(session_id, seek_time)

    hls_url = "#{api_base_url}/api/playback/hls/#{session_id}/playlist.m3u8?t=#{Time.now.to_f}"
    render json: {
      hlsUrl: hls_url,
      seekTime: seek_time,
      seekBase: seek_time
    }
  rescue => e
    Rails.logger.error "[Playback] seek error: #{e.message}"
    render json: { error: e.message }, status: :internal_server_error
  end

  # POST /api/playback/stop
  def stop_playback
    session_id = params[:session]
    TranscoderService.stop_session(session_id) if session_id.present?

    time = params[:time].to_i
    duration = params[:duration].to_i

    if duration > 0
      if params[:episode_id].present?
        ep = Episode.find_by(id: params[:episode_id])
        if ep
          ep.update_progress!(time, duration)
          ep.mark_watched! if time.to_f / duration >= Watchable::WATCHED_THRESHOLD
        end
      end

      if params[:movie_id].present?
        movie = Movie.find_by(id: params[:movie_id])
        if movie
          movie.update_progress!(time, duration)
          movie.mark_watched! if time.to_f / duration >= Watchable::WATCHED_THRESHOLD
        end
      end
    end

    render json: { ok: true }
  end

  # GET /api/playback/subtitles?session=X
  #
  # Serves WebVTT subtitles with timestamps shifted by the current seek
  # offset. Long-polls up to 30 seconds while extract_subtitles_async is
  # still running so the player's HTTP fetch blocks transparently — no
  # client-side polling needed. Returns empty VTT if extraction failed
  # or the session was reset.
  def subtitles
    session_id = params[:session]
    vtt = TranscoderService.get_session_subtitle(session_id)

    if vtt.blank? && TranscoderService.subtitle_extracting?(session_id)
      deadline = Time.now + 30
      while vtt.blank? &&
            TranscoderService.subtitle_extracting?(session_id) &&
            Time.now < deadline
        sleep 0.5
        vtt = TranscoderService.get_session_subtitle(session_id)
      end
      # One last read in case extraction finished in the gap between the
      # loop guard and the read.
      vtt ||= TranscoderService.get_session_subtitle(session_id)
    end

    if vtt.blank?
      return render plain: "WEBVTT\n\n", content_type: "text/vtt"
    end

    seek_base = TranscoderService.current_seek_time(session_id)
    shifted = TranscoderService.shift_vtt(vtt, seek_base)

    response.headers["Cache-Control"] = "no-cache, no-store"
    render plain: shifted, content_type: "text/vtt"
  end

  # POST /api/playback/switch_audio
  # Body: { session, audioStreamIndex, currentVideoTime }
  def switch_audio
    session_id = params[:session]
    audio_index = params[:audioStreamIndex].to_i
    current_time = params[:currentVideoTime].to_f

    info = TranscoderService.session_info(session_id)
    return render(json: { error: "No active session" }, status: :not_found) unless info

    active_sub_index = info[:active_subtitle_index]
    had_subtitle = TranscoderService.get_session_subtitle(session_id).present?

    abs_time = (info[:seek_time] || 0) + current_time

    TranscoderService.start_session(session_id, info[:file_path], abs_time,
      audio_stream_index: audio_index,
      burn_subtitle_index: info[:burn_subtitle_index],
      duration: info[:duration],
      force_transcode: info[:force_transcode])

    if had_subtitle && active_sub_index
      vtt = TranscoderService.extract_subtitles(info[:file_path], active_sub_index)
      TranscoderService.set_session_subtitle(session_id, vtt, stream_index: active_sub_index) if vtt
    end

    hls_url = "#{api_base_url}/api/playback/hls/#{session_id}/playlist.m3u8?t=#{Time.now.to_f}"
    render json: { hlsUrl: hls_url, seekTime: abs_time, seekBase: abs_time }
  rescue => e
    render json: { error: e.message }, status: :internal_server_error
  end

  # POST /api/playback/switch_subtitle
  def switch_subtitle
    session_id = params[:session]
    stream_index = params[:subtitleStreamIndex]

    info = TranscoderService.session_info(session_id)
    return render(json: { error: "No active session" }, status: :not_found) unless info

    TranscoderService.set_session_subtitle(session_id, nil)

    if stream_index.blank? || stream_index.to_i < 0
      Rails.logger.info "[Subtitle] Disabled subtitles"
      return render(json: { subtitleUrl: nil })
    end

    Rails.logger.info "[Subtitle] Switching to subtitle stream #{stream_index} for file: #{info[:file_path]}"
    # Kick off extraction in the background and return the URL immediately.
    # The /subtitles endpoint long-polls while ffmpeg works, so the player
    # just waits on its HTTP fetch instead of staring at a blocked switch
    # request for 10-15 seconds.
    TranscoderService.extract_subtitles_async(session_id, info[:file_path], stream_index.to_i)
    subtitle_url = "#{api_base_url}/api/playback/subtitles?session=#{session_id}&t=#{Time.now.to_i}"
    render json: { subtitleUrl: subtitle_url }
  rescue => e
    Rails.logger.error "[Subtitle] switch_subtitle error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    render json: { error: e.message }, status: :internal_server_error
  end

  # POST /api/playback/switch_bitmap_subtitle
  def switch_bitmap_subtitle
    session_id = params[:session]
    sub_index = params[:subtitleStreamIndex]
    current_time = params[:currentVideoTime].to_f

    info = TranscoderService.session_info(session_id)
    return render(json: { error: "No active session" }, status: :not_found) unless info

    TranscoderService.set_session_subtitle(session_id, nil)

    burn_index = sub_index.present? && sub_index.to_i >= 0 ? sub_index.to_i : nil
    abs_time = (info[:seek_time] || 0) + current_time

    TranscoderService.start_session(session_id, info[:file_path], abs_time,
      audio_stream_index: info[:audio_stream_index],
      burn_subtitle_index: burn_index,
      duration: info[:duration],
      force_transcode: info[:force_transcode])

    hls_url = "#{api_base_url}/api/playback/hls/#{session_id}/playlist.m3u8?t=#{Time.now.to_f}"
    render json: { hlsUrl: hls_url, seekTime: abs_time, seekBase: abs_time }
  rescue => e
    render json: { error: e.message }, status: :internal_server_error
  end

  # ── direct_play endpoint ────────────────────────────────────────────
  #
  # GET /api/playback/file/:session_id
  #
  # Serves the source file with full HTTP byte-range support so the player
  # (ExoPlayer / browser <video>) can seek without having to download the
  # whole multi-gigabyte file. Rails's `send_file` did NOT honour the
  # Range header on the test rig — every request returned 200 OK with
  # zero or full body — so we parse the Range manually and stream the
  # requested slice via Enumerator. ExoPlayer issues many small range
  # requests (initial header, MKV Cues at end, then sequential reads
  # from the playhead) and each one resolves in ~10ms.
  CHUNK_BYTES = 64 * 1024
  RANGE_HEADER = /\Abytes=(\d+)-(\d*)\z/

  def file
    session_id = params[:session_id]
    file_path = TranscoderService.direct_play_file_path(session_id)
    return head(:not_found) unless file_path
    return head(:not_found) unless File.exist?(file_path)

    size = File.size(file_path)
    content_type = direct_play_content_type(file_path)

    response.headers["Accept-Ranges"] = "bytes"
    response.headers["Cache-Control"] = "no-store"
    response.headers["Content-Type"] = content_type
    response.headers["Content-Disposition"] = "inline; filename=\"#{File.basename(file_path)}\""

    range_header = request.headers["Range"]
    if range_header.present? && (m = range_header.match(RANGE_HEADER))
      start_byte = m[1].to_i
      end_byte = m[2].present? ? m[2].to_i : size - 1
      end_byte = [ end_byte, size - 1 ].min
      if start_byte > end_byte || start_byte >= size
        response.headers["Content-Range"] = "bytes */#{size}"
        return head(:requested_range_not_satisfiable)
      end
      length = end_byte - start_byte + 1

      response.status = 206
      response.headers["Content-Range"] = "bytes #{start_byte}-#{end_byte}/#{size}"
      response.headers["Content-Length"] = length.to_s

      if request.head?
        response.body = ""
        return
      end

      self.response_body = Enumerator.new do |yielder|
        File.open(file_path, "rb") do |f|
          f.seek(start_byte)
          remaining = length
          while remaining.positive?
            chunk = f.read([ remaining, CHUNK_BYTES ].min)
            break if chunk.nil? || chunk.empty?
            yielder << chunk
            remaining -= chunk.bytesize
          end
        end
      end
      return
    end

    response.headers["Content-Length"] = size.to_s
    if request.head?
      response.body = ""
      return
    end

    self.response_body = Enumerator.new do |yielder|
      File.open(file_path, "rb") do |f|
        while (chunk = f.read(CHUNK_BYTES))
          yielder << chunk
        end
      end
    end
  end

  def direct_play_content_type(file_path)
    case File.extname(file_path).downcase
    when ".mp4", ".m4v" then "video/mp4"
    when ".mov"         then "video/quicktime"
    when ".mkv"         then "video/x-matroska"
    when ".webm"        then "video/webm"
    when ".avi"         then "video/x-msvideo"
    when ".ts", ".m2ts" then "video/mp2t"
    else                     "application/octet-stream"
    end
  end

  # ── HLS endpoints ──────────────────────────────────────────────────

  # GET /api/playback/hls/:session_id/playlist.m3u8
  def hls_playlist
    session_id = params[:session_id]

    return head :not_found unless TranscoderService.active?(session_id)

    playlist_path = TranscoderService.hls_playlist_path(session_id)
    return render(plain: "Session not in HLS mode", status: :bad_request) unless playlist_path

    # Wait up to 12 seconds for ffmpeg to create the playlist. Cold start
    # for a 4K HEVC HDR source under tonemap + audio_transcode (TrueHD →
    # AAC) commonly takes 6-10 seconds before the first segment + manifest
    # are written. 3 seconds was short enough that hls.js bailed before
    # ffmpeg had finished warming up — the user saw "first play hangs;
    # switch audio fixes it" because the second ffmpeg startup hit warm
    # filesystem + library caches.
    40.times do
      break if File.exist?(playlist_path)
      sleep 0.3
    end

    return render(plain: "Playlist not ready", status: :service_unavailable) unless File.exist?(playlist_path)

    playlist = File.read(playlist_path)

    # If ffmpeg exited but the playlist is missing the ENDLIST tag, append it
    # so clients stop polling.
    unless TranscoderService.ffmpeg_running? || playlist.include?("#EXT-X-ENDLIST")
      playlist = playlist.strip + "\n#EXT-X-ENDLIST\n"
    end

    response.headers["Content-Type"] = "application/vnd.apple.mpegurl"
    response.headers["Cache-Control"] = "max-age=1"
    render plain: playlist
  end

  # GET /api/playback/hls/:session_id/:asset
  # Serves both init.mp4 and segment_N.m4s.
  def hls_asset
    session_id = params[:session_id]
    asset_name = params[:asset]

    return head :not_found unless TranscoderService.active?(session_id)

    asset_path = TranscoderService.hls_asset_path(session_id, asset_name)
    return head :bad_request unless asset_path

    # Wait up to 8s for ffmpeg to finish writing the segment. Longer than the
    # 6-second segment duration, so we respond successfully even when encoding
    # briefly lags behind wall-clock playback.
    40.times do
      break if File.exist?(asset_path)
      sleep 0.2
    end

    return head :not_found unless File.exist?(asset_path)

    # Must not cache: segment filenames reset to segment_0 on every
    # seek/session restart, so the same URL carries different content
    # across sessions. Caching would hand back stale bytes and desync
    # hls.js's PTS tracking.
    response.headers["Cache-Control"] = "no-store"
    send_file asset_path,
      type: "video/mp4",
      disposition: "inline"
  end

  private

  # Locate the Episode or Movie row backing a given file path, so the
  # cached tech_metadata can be reused on playback start. nil when the
  # file isn't tracked yet (e.g. ad-hoc playback of a path).
  def find_record_for(file_path)
    Episode.find_by(file_path: file_path) || Movie.find_by(file_path: file_path)
  end

  def find_preference
    if params[:type] == "episode" && params[:show_id].present?
      PlaybackPreference.find_by(show_id: params[:show_id])
    elsif params[:type] == "movie" && params[:movie_id].present?
      PlaybackPreference.find_by(movie_id: params[:movie_id])
    end
  end

  def preference_attrs
    {
      audio_language: params[:audioLanguage],
      audio_codec: params[:audioCodec],
      audio_channels: params[:audioChannels],
      subtitle_language: params[:subtitleLanguage],
      subtitle_off: params[:subtitleOff] ? 1 : 0,
      subtitle_size: params[:subtitleSize] || "medium",
      subtitle_style: params[:subtitleStyle] || "classic"
    }
  end

  # Pick the audio track. Selection precedence (most specific first):
  #   1. Saved (language, codec, channels) — disambiguates AAC stereo vs
  #      AAC 5.1 from the same source where lang+codec are identical.
  #   2. Saved (language, codec) — handles TrueHD eng + AC3 eng pairs.
  #   3. Saved language alone — prefer a client-decodable codec to stay
  #      direct_stream / direct_play.
  #   4. English with same playable preference.
  #   5. First available track.
  def select_audio_track(audio_streams, prefs, codec_support = nil)
    return nil if audio_streams.empty?

    saved_lang     = prefs && prefs[:audioLanguage].presence
    saved_codec    = prefs && prefs[:audioCodec].presence
    saved_channels = prefs && prefs[:audioChannels].presence
    desired_lang = saved_lang || "eng"

    if saved_lang && saved_codec && saved_channels
      exact = audio_streams.find { |s|
        matches_language?(s[:language], saved_lang) &&
          s[:codec] == saved_codec &&
          s[:channels].to_i == saved_channels.to_i
      }
      return exact[:index] if exact
    end

    if saved_lang && saved_codec
      exact = audio_streams.find { |s|
        matches_language?(s[:language], saved_lang) && s[:codec] == saved_codec
      }
      return exact[:index] if exact
    end

    in_lang = audio_streams.select { |s| matches_language?(s[:language], desired_lang) }
    in_lang = audio_streams if in_lang.empty?

    playable = in_lang.find { |s| TranscoderService.allowed_audio_codec?(s[:codec], codec_support) }
    return playable[:index] if playable

    # Even when no codec is directly playable, bias toward simple codecs
    # that re-encode quickly. TrueHD/DTS-HD MA decoders need 1-2 seconds
    # of warmup before producing samples; on a cold first play that pushes
    # the first HLS segment past the client's patience window and the user
    # sees "playback fails until I switch audio." Picking AC3/AAC/etc. as
    # the source keeps cold start under the timeout.
    cheap = in_lang.find { |s| CHEAP_AUDIO_CODECS.include?(s[:codec]) }
    (cheap || in_lang.first)[:index]
  end

  CHEAP_AUDIO_CODECS = %w[aac ac3 eac3 mp3 flac opus vorbis].freeze

  def matches_language?(stream_language, requested)
    return true if stream_language.to_s == requested.to_s
    # ffprobe sometimes returns the 2-letter ISO code, sometimes the 3-letter.
    requested == "eng" && stream_language.to_s == "en" ||
      requested == "en" && stream_language.to_s == "eng"
  end

  def select_subtitle_track(subtitle_streams, prefs)
    return [ nil, false ] if subtitle_streams.empty?

    if prefs && prefs[:subtitleOff]
      return [ nil, false ]
    end

    if prefs && prefs[:subtitleLanguage].present?
      saved_text = subtitle_streams.find { |s| s[:isText] && s[:language] == prefs[:subtitleLanguage] }
      return [ saved_text[:index], false ] if saved_text

      saved_bitmap = subtitle_streams.find { |s| !s[:isText] && s[:language] == prefs[:subtitleLanguage] }
      return [ saved_bitmap[:index], true ] if saved_bitmap
    end

    # No saved preference: only auto-pick a text subtitle. Auto-burning a
    # bitmap (PGS/VOBSUB) track forces full_transcode and pushes encode speed
    # below 1× realtime on 4K sources, which the player then reads as a
    # network error storm. Require an explicit user choice for bitmap subs.
    text_sub = subtitle_streams.find { |s| s[:isText] }
    return [ text_sub[:index], false ] if text_sub

    [ nil, false ]
  end

  def api_base_url
    host = request.headers["X-Forwarded-Host"] || request.host_with_port
    protocol = request.headers["X-Forwarded-Proto"] || request.protocol.sub("://", "")
    @api_base_url ||= "#{protocol}://#{host}"
  end
end
