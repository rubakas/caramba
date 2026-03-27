class EpisodesController < ApplicationController
  def play
    episode = Episode.find(params[:id])

    # Mark this and all prior episodes as watched
    Episode.where(
      'season_number < :s OR (season_number = :s AND episode_number <= :e)',
      s: episode.season_number, e: episode.episode_number
    ).where(watched: false).update_all(watched: true, last_watched_at: Time.current)

    episode.mark_watched!

    # Create watch history entry
    history = episode.watch_histories.create!(started_at: Time.current)

    # Launch VLC with resume support
    start_time = episode.in_progress? ? episode.progress_seconds : nil
    vlc_pid = VlcPlayer.play(episode.file_path, start_time: start_time)

    # Store current playback session info
    session[:current_episode_id] = episode.id
    session[:current_history_id] = history.id
    session[:vlc_pid] = vlc_pid

    redirect_to root_path, notice: "Playing #{episode.code}: #{episode.title}"
  end

  def toggle_watched
    episode = Episode.find(params[:id])

    if episode.watched?
      episode.mark_unwatched!
    else
      episode.mark_watched!
    end

    redirect_to root_path
  end

  def scan
    count = MediaScanner.scan!
    redirect_to root_path, notice: "Scanned #{count} episodes from disk"
  end
end
