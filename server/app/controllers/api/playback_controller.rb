class Api::PlaybackController < Api::BaseController
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

      # Auto-mark watched at 90%
      ep.mark_watched! if time.to_f / duration >= 0.9
    end

    if params[:movie_id].present?
      movie = Movie.find(params[:movie_id])
      movie.update_progress!(time, duration)

      # Auto-mark watched at 90%
      movie.mark_watched! if time.to_f / duration >= 0.9
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
end
