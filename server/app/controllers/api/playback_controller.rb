class Api::PlaybackController < Api::BaseController
  # The stream action uses ActionController::Live to pipe ffmpeg's
  # fragmented MP4 output directly to the HTTP response.
  include ActionController::Live

  # ── Existing endpoints ──────────────────────────────────────────────

  # POST /api/playback/report_progress
  # Body: { type: "episode"|"movie", episode_id, movie_id, watch_history_id, time, duration }
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

      # Auto-mark watched at threshold
      ep.mark_watched! if time.to_f / duration >= Watchable::WATCHED_THRESHOLD
    end

    if params[:movie_id].present?
      movie = Movie.find(params[:movie_id])
      movie.update_progress!(time, duration)

      # Auto-mark watched at threshold
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
  # Body: { type, seriesId, movieId, audioLanguage, subtitleLanguage, subtitleOff, subtitleSize, subtitleStyle }
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
  # Body: { filePath, startTime, prefs: { audioLanguage, subtitleLanguage, subtitleOff } }
  # Returns: { streamUrl, sessionId, duration, startTime, seekBase, ... }
  def start
    file_path = params[:filePath]
    start_time = (params[:startTime] || 0).to_f
    prefs = params[:prefs]

    return render(json: { error: "filePath required" }, status: :unprocessable_entity) unless file_path.present?
    return render(json: { error: "File not found: #{file_path}" }, status: :unprocessable_entity) unless File.exist?(file_path)

    info = TranscoderService.probe(file_path)

    audio_stream_index = select_audio_track(info[:audioStreams], prefs)
    subtitle_stream_index, is_bitmap = select_subtitle_track(info[:subtitleStreams], prefs)

    session_id = SecureRandom.hex(8)

    TranscoderService.start_session(session_id, file_path, start_time,
      audio_stream_index: audio_stream_index,
      burn_subtitle_index: is_bitmap ? subtitle_stream_index : nil,
      duration: info[:duration])

    session[:playback_session_id] = session_id

    # Extract text subtitles in the background
    if subtitle_stream_index && !is_bitmap
      Thread.new do
        vtt = TranscoderService.extract_subtitles(file_path, subtitle_stream_index)
        TranscoderService.set_session_subtitle(session_id, vtt) if vtt
      end
    end

    stream_url = "#{api_base_url}/api/playback/stream/#{session_id}"
    subtitle_url = subtitle_stream_index && !is_bitmap ? "#{api_base_url}/api/playback/subtitles?session=#{session_id}" : nil

    render json: {
      streamUrl: stream_url,
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
      isBitmapSubtitle: is_bitmap
    }
  rescue => e
    Rails.logger.error "[Playback] start error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    render json: { error: e.message }, status: :internal_server_error
  end

  # GET /api/playback/stream/:session_id
  #
  # Pipes ffmpeg's fragmented MP4 stdout directly to the HTTP response.
  # This mirrors the desktop Electron stream:// protocol handler.
  # The browser's <video> element can play fMP4 natively.
  def stream
    session_id = params[:session_id]

    unless TranscoderService.active?(session_id)
      response.headers["Content-Type"] = "text/plain"
      response.stream.write "Session not found"
      response.stream.close
      return
    end

    io = TranscoderService.stream_io
    unless io
      response.headers["Content-Type"] = "text/plain"
      response.stream.write "No active stream"
      response.stream.close
      return
    end

    response.headers["Content-Type"] = "video/mp4"
    response.headers["Cache-Control"] = "no-cache, no-store"
    response.headers["X-Accel-Buffering"] = "no"  # disable nginx buffering if proxied
    response.headers["Last-Modified"] = Time.now.httpdate  # prevent Rack::ConditionalGet buffering
    response.headers["ETag"] = nil  # prevent Rack::ETag buffering

    # Pipe ffmpeg stdout → HTTP response in 64KB chunks.
    # Force binary encoding so Rack/Puma don't attempt any re-encoding.
    begin
      while (chunk = io.read(65_536))
        response.stream.write(chunk)
      end
    rescue IOError, Errno::EPIPE, ActionController::Live::ClientDisconnected => e
      Rails.logger.debug "[Stream] client disconnected or pipe closed: #{e.class}"
    ensure
      response.stream.close
    end
  end

  # POST /api/playback/seek
  # Body: { session, seekTime }
  #
  # Kills the current ffmpeg process and restarts from the target time.
  # Returns a new stream URL (with cache-buster) for the client to re-set video.src.
  def seek
    session_id = params[:session]
    seek_time = params[:seekTime].to_f

    info = TranscoderService.session_info(session_id)
    return render(json: { error: "No active session" }, status: :not_found) unless info

    TranscoderService.seek_session(session_id, seek_time)

    stream_url = "#{api_base_url}/api/playback/stream/#{session_id}?t=#{Time.now.to_f}"

    render json: {
      streamUrl: stream_url,
      seekTime: seek_time,
      seekBase: seek_time
    }
  rescue => e
    Rails.logger.error "[Playback] seek error: #{e.message}"
    render json: { error: e.message }, status: :internal_server_error
  end

  # POST /api/playback/stop
  # Body: { session }
  def stop_playback
    session_id = params[:session]
    TranscoderService.stop_session(session_id) if session_id.present?
    render json: { ok: true }
  end

  # GET /api/playback/subtitles?session=X
  #
  # Serves extracted WebVTT with timestamps shifted to match the current
  # seek position.  After a seek, video.currentTime restarts from 0, but
  # the extracted VTT has absolute timestamps from the source file.
  def subtitles
    session_id = params[:session]
    vtt = TranscoderService.get_session_subtitle(session_id)

    if vtt.blank?
      return render plain: "WEBVTT\n\n", content_type: "text/vtt"
    end

    # Shift timestamps to align with current seek base
    seek_base = TranscoderService.current_seek_time(session_id)
    shifted = TranscoderService.shift_vtt(vtt, seek_base)

    response.headers["Cache-Control"] = "no-cache, no-store"
    render plain: shifted, content_type: "text/vtt"
  end

  # POST /api/playback/switch_audio
  # Body: { session, audioStreamIndex, currentVideoTime }
  # Returns: { streamUrl, seekTime, seekBase }
  #
  # Audio switches require a full session restart because the ffmpeg
  # encode parameters change.
  def switch_audio
    session_id = params[:session]
    audio_index = params[:audioStreamIndex].to_i
    current_time = params[:currentVideoTime].to_f

    info = TranscoderService.session_info(session_id)
    return render(json: { error: "No active session" }, status: :not_found) unless info

    # Calculate absolute time (seekBase + relative currentTime)
    abs_time = (info[:seek_time] || 0) + current_time

    TranscoderService.start_session(session_id, info[:file_path], abs_time,
      audio_stream_index: audio_index,
      burn_subtitle_index: info[:burn_subtitle_index],
      duration: info[:duration])

    stream_url = "#{api_base_url}/api/playback/stream/#{session_id}?t=#{Time.now.to_f}"

    render json: {
      streamUrl: stream_url,
      seekTime: abs_time,
      seekBase: abs_time
    }
  rescue => e
    render json: { error: e.message }, status: :internal_server_error
  end

  # POST /api/playback/switch_subtitle
  # Body: { session, subtitleStreamIndex }
  # Returns: { subtitleUrl }
  def switch_subtitle
    session_id = params[:session]
    stream_index = params[:subtitleStreamIndex]

    info = TranscoderService.session_info(session_id)
    return render(json: { error: "No active session" }, status: :not_found) unless info

    TranscoderService.set_session_subtitle(session_id, nil)

    if stream_index.blank? || stream_index.to_i < 0
      return render(json: { subtitleUrl: nil })
    end

    vtt = TranscoderService.extract_subtitles(info[:file_path], stream_index.to_i)
    if vtt.present?
      TranscoderService.set_session_subtitle(session_id, vtt)
      render json: { subtitleUrl: "#{api_base_url}/api/playback/subtitles?session=#{session_id}&t=#{Time.now.to_i}" }
    else
      render json: { subtitleUrl: nil }
    end
  rescue => e
    render json: { error: e.message }, status: :internal_server_error
  end

  # POST /api/playback/switch_bitmap_subtitle
  # Body: { session, subtitleStreamIndex, currentVideoTime }
  # Returns: { streamUrl, seekTime, seekBase }
  def switch_bitmap_subtitle
    session_id = params[:session]
    sub_index = params[:subtitleStreamIndex]
    current_time = params[:currentVideoTime].to_f

    info = TranscoderService.session_info(session_id)
    return render(json: { error: "No active session" }, status: :not_found) unless info

    TranscoderService.set_session_subtitle(session_id, nil)

    burn_index = sub_index.present? && sub_index.to_i >= 0 ? sub_index.to_i : nil

    # Calculate absolute time
    abs_time = (info[:seek_time] || 0) + current_time

    TranscoderService.start_session(session_id, info[:file_path], abs_time,
      audio_stream_index: info[:audio_stream_index],
      burn_subtitle_index: burn_index,
      duration: info[:duration])

    stream_url = "#{api_base_url}/api/playback/stream/#{session_id}?t=#{Time.now.to_f}"

    render json: {
      streamUrl: stream_url,
      seekTime: abs_time,
      seekBase: abs_time
    }
  rescue => e
    render json: { error: e.message }, status: :internal_server_error
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
    @api_base_url ||= "#{request.protocol}#{request.host_with_port}"
  end
end
