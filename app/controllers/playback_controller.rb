# Returns VLC playback status as JSON — polled by the frontend via setInterval
# to keep episode progress up to date while watching.
class PlaybackController < ApplicationController
  skip_forgery_protection only: :status

  # GET /playback/status.json
  def status
    episode_id = session[:current_episode_id]
    history_id = session[:current_history_id]
    series_slug = session[:current_series_slug]

    vlc_status = VlcPlayer.status

    unless vlc_status && episode_id
      render json: { playing: false }
      return
    end

    episode = Episode.find_by(id: episode_id)
    unless episode
      render json: { playing: false }
      return
    end

    playing = %w[playing paused].include?(vlc_status[:state])

    # Update episode progress
    if vlc_status[:time] > 0
      episode.update!(
        progress_seconds: vlc_status[:time],
        duration_seconds: vlc_status[:length]
      )
    end

    # Update watch history entry
    if history_id && vlc_status[:time] > 0
      history = WatchHistory.find_by(id: history_id)
      if history
        history.update!(
          progress_seconds: vlc_status[:time],
          duration_seconds: vlc_status[:length],
          ended_at: playing ? nil : Time.current
        )
      end
    end

    # If VLC stopped, finalize the session
    unless playing
      if history_id
        history = WatchHistory.find_by(id: history_id)
        history&.update!(ended_at: Time.current)
      end
      session.delete(:current_episode_id)
      session.delete(:current_history_id)
      session.delete(:current_series_slug)
      session.delete(:vlc_pid)
    end

    render json: {
      playing: playing,
      state: vlc_status[:state],
      episode_id: episode.id,
      episode_code: episode.code,
      episode_title: episode.title,
      series_name: episode.series.name,
      series_slug: series_slug,
      time: vlc_status[:time],
      length: vlc_status[:length],
      position: vlc_status[:position],
      progress_display: ApplicationHelper.format_time(vlc_status[:time]),
      duration_display: ApplicationHelper.format_time(vlc_status[:length])
    }
  end
end
