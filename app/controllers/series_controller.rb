class SeriesController < ApplicationController
  before_action :set_series, only: %i[show destroy scan]

  def index
    @all_series = Series.by_name.includes(:episodes)
  end

  def show
    @seasons = @series.episodes.grouped_by_season
    @last_watched = @series.last_watched_episode
    @next_episode = @series.next_episode
    @resume_episode = @series.resumable_episode
  end

  def new; end

  def create
    path = params[:media_path].to_s.strip

    if path.blank?
      flash[:alert] = 'Please provide a media folder path'
      render :new, status: :unprocessable_entity
      return
    end

    unless Dir.exist?(path)
      flash[:alert] = "Folder not found: #{path}"
      render :new, status: :unprocessable_entity
      return
    end

    series = MediaScanner.add_from_path!(path)
    redirect_to series_path(series.slug), notice: "Added '#{series.name}' with #{series.total_episodes} episodes"
  rescue ActiveRecord::RecordInvalid => e
    flash[:alert] = "Could not add series: #{e.message}"
    render :new, status: :unprocessable_entity
  end

  def destroy
    name = @series.name
    @series.destroy!
    redirect_to root_path, notice: "'#{name}' has been removed"
  end

  def scan
    count = MediaScanner.scan!(@series)
    redirect_to series_path(@series.slug), notice: "Rescanned #{count} episodes"
  end

  private

  def set_series
    @series = Series.find_by!(slug: params[:slug])
  end
end
