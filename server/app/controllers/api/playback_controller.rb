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

  # GET /api/playback/preferences?type=episode&series_id=1 or ?type=movie&movie_id=1
  def preferences
    pref = find_preference
    return render(json: nil) unless pref

    render json: {
      audioLanguage: pref.audio_language,
      subtitleLanguage: pref.subtitle_language,
      subtitleOff: pref.subtitle_off != 0,
      subtitleSize: pref.subtitle_size || "medium",
      subtitleStyle: pref.subtitle_style || "classic"
    }
  end

  # POST /api/playback/preferences
  def save_preferences
    if params[:type] == "episode" && params[:seriesId].present?
      pref = PlaybackPreference.find_or_initialize_by(series_id: params[:seriesId])
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

    info = TranscoderService.probe(file_path)

    audio_stream_index = select_audio_track(info[:audioStreams], prefs)
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

    hls_url = "#{api_base_url}/api/playback/hls/#{session_id}/playlist.m3u8"
    subtitle_url = subtitle_stream_index && !is_bitmap ? "#{api_base_url}/api/playback/subtitles?session=#{session_id}" : nil

    render json: {
      hlsUrl: hls_url,
      sessionId: session_id,
      duration: info[:duration],
      startTime: start_time,
      seekBase: start_time,
      subtitleUrl: subtitle_url,
      video: info[:video],
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
  # offset. Returns empty VTT if not yet extracted.
  def subtitles
    session_id = params[:session]
    vtt = TranscoderService.get_session_subtitle(session_id)

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
    vtt = TranscoderService.extract_subtitles(info[:file_path], stream_index.to_i)
    if vtt.present?
      TranscoderService.set_session_subtitle(session_id, vtt, stream_index: stream_index.to_i)
      subtitle_url = "#{api_base_url}/api/playback/subtitles?session=#{session_id}&t=#{Time.now.to_i}"
      Rails.logger.info "[Subtitle] Extracted and enabled stream #{stream_index}, VTT size: #{vtt.bytesize} bytes, #{vtt.lines.count} lines"
      render json: { subtitleUrl: subtitle_url }
    else
      Rails.logger.warn "[Subtitle] Failed to extract stream #{stream_index}"
      render json: { subtitleUrl: nil }
    end
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

  # ── HLS endpoints ──────────────────────────────────────────────────

  # GET /api/playback/hls/:session_id/playlist.m3u8
  def hls_playlist
    session_id = params[:session_id]

    return head :not_found unless TranscoderService.active?(session_id)

    playlist_path = TranscoderService.hls_playlist_path(session_id)
    return render(plain: "Session not in HLS mode", status: :bad_request) unless playlist_path

    # Wait up to 3 seconds for ffmpeg to create the playlist
    10.times do
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

    # Wait up to 4s for ffmpeg to finish writing the segment. Longer than the
    # segment duration, so we respond successfully even when encoding briefly
    # lags behind wall-clock playback.
    20.times do
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

  def find_preference
    if params[:type] == "episode" && params[:series_id].present?
      PlaybackPreference.find_by(series_id: params[:series_id])
    elsif params[:type] == "movie" && params[:movie_id].present?
      PlaybackPreference.find_by(movie_id: params[:movie_id])
    end
  end

  def preference_attrs
    {
      audio_language: params[:audioLanguage],
      subtitle_language: params[:subtitleLanguage],
      subtitle_off: params[:subtitleOff] ? 1 : 0,
      subtitle_size: params[:subtitleSize] || "medium",
      subtitle_style: params[:subtitleStyle] || "classic"
    }
  end

  def select_audio_track(audio_streams, prefs)
    return nil if audio_streams.empty?

    if prefs && prefs[:audioLanguage].present?
      saved = audio_streams.find { |s| s[:language] == prefs[:audioLanguage] }
      return saved ? saved[:index] : audio_streams.first[:index]
    end

    eng = audio_streams.find { |s| %w[eng en].include?(s[:language]) }
    eng ? eng[:index] : audio_streams.first[:index]
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

    text_sub = subtitle_streams.find { |s| s[:isText] }
    return [ text_sub[:index], false ] if text_sub

    bitmap_sub = subtitle_streams.find { |s| !s[:isText] }
    return [ bitmap_sub[:index], true ] if bitmap_sub

    [ nil, false ]
  end

  def api_base_url
    host = request.headers["X-Forwarded-Host"] || request.host_with_port
    protocol = request.headers["X-Forwarded-Proto"] || request.protocol.sub("://", "")
    @api_base_url ||= "#{protocol}://#{host}"
  end
end
