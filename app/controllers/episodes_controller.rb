class EpisodesController < ApplicationController
  before_action :set_series
  before_action :set_episode

  def play
    # Mark this and all prior episodes in this series as watched
    @series.episodes.where(
      'season_number < :s OR (season_number = :s AND episode_number <= :e)',
      s: @episode.season_number, e: @episode.episode_number
    ).where(watched: false).update_all(watched: true, last_watched_at: Time.current)

    @episode.mark_watched!

    # Create watch history entry
    history = @episode.watch_histories.create!(started_at: Time.current)

    # Launch VLC with resume support
    start_time = @episode.in_progress? ? @episode.progress_seconds : nil
    vlc_pid = VlcPlayer.play(@episode.file_path, start_time: start_time)

    # Store current playback session info
    session[:current_episode_id] = @episode.id
    session[:current_history_id] = history.id
    session[:current_series_slug] = @series.slug
    session[:vlc_pid] = vlc_pid

    redirect_to series_path(@series.slug), notice: "Playing #{@episode.code}: #{@episode.title}"
  end

  def toggle
    if @episode.watched?
      @episode.mark_unwatched!
    else
      @episode.mark_watched!
    end

    redirect_to series_path(@series.slug)
  end

  private

  def set_series
    @series = Series.find_by!(slug: params[:series_slug])
  end

  def set_episode
    @episode = @series.episodes.find(params[:id])
  end
end
