class Api::SeriesController < Api::BaseController
  # GET /api/series
  def index
    series = Series.all.order(:name)
    render json: series.map { |s| series_with_counts(s) }
  end

  # GET /api/series/:slug
  def show
    s = Series.find_by!(slug: params[:slug])
    render json: series_with_counts(s)
  end

  # GET /api/series/:slug/full
  # Combined handler: returns everything SeriesShow page needs in one request.
  def full
    s = Series.find_by!(slug: params[:slug])
    eps = s.episodes.ordered
    seasons = s.episodes.distinct.pluck(:season_number).compact.sort
    resume_ep = s.episodes
      .where("progress_seconds > 0 AND duration_seconds > 0")
      .where("CAST(progress_seconds AS REAL) / duration_seconds < 0.9")
      .order(last_watched_at: :desc)
      .first
    next_ep = next_up_for(s)

    # Attach download status to each episode
    downloads = Download.where(episode_id: eps.map(&:id))
    dl_by_episode = downloads.index_by(&:episode_id)

    episodes_json = eps.map do |ep|
      ep.as_json.merge("download" => dl_by_episode[ep.id]&.as_json)
    end

    render json: {
      series: series_with_counts(s),
      episodes: episodes_json,
      seasons: seasons,
      resumeEp: resume_ep,
      nextEp: next_ep
    }
  end

  # GET /api/series/:slug/episodes
  def episodes
    s = Series.find_by!(slug: params[:slug])
    render json: s.episodes.ordered
  end

  # GET /api/series/:slug/seasons
  def seasons
    s = Series.find_by!(slug: params[:slug])
    render json: s.episodes.distinct.pluck(:season_number).compact.sort
  end

  # GET /api/series/:slug/resumable
  def resumable
    s = Series.find_by!(slug: params[:slug])
    ep = s.episodes
      .where("progress_seconds > 0 AND duration_seconds > 0")
      .where("CAST(progress_seconds AS REAL) / duration_seconds < 0.9")
      .order(last_watched_at: :desc)
      .first
    render json: ep
  end

  # GET /api/series/:slug/next_up
  def next_up
    s = Series.find_by!(slug: params[:slug])
    render json: next_up_for(s)
  end

  # POST /api/series
  # Server-side equivalent of addSeries — scans folder, fetches metadata
  def create
    folder_path = params[:folder_path]&.strip
    return render(json: { error: "folder_path required" }, status: :unprocessable_entity) unless folder_path.present?

    name = MediaScannerService.name_from_path(folder_path)
    s = Series.find_by(media_path: folder_path) || Series.create!(name: name, media_path: folder_path)

    MediaScannerService.scan(s)
    TvmazeService.fetch_for_series(s)

    render json: series_with_counts(s.reload), status: :created
  end

  # POST /api/series/:slug/scan
  def scan
    s = Series.find_by!(slug: params[:slug])
    count = MediaScannerService.scan(s)
    render json: { scanned: count }
  end

  # POST /api/series/:slug/refresh_metadata
  def refresh_metadata
    s = Series.find_by!(slug: params[:slug])
    result = TvmazeService.fetch_for_series(s)
    render json: { success: result }
  end

  # DELETE /api/series/:slug
  def destroy
    s = Series.find_by!(slug: params[:slug])
    # Clean up downloaded files
    s.downloads.each do |dl|
      File.delete(dl.file_path) if dl.file_path && File.exist?(dl.file_path)
    rescue SystemCallError
      # ignore filesystem errors
    end
    s.destroy!
    head :no_content
  end

  private

  def series_with_counts(s)
    total = s.episodes.count
    watched = s.episodes.watched.count
    s.as_json.merge(
      "season_count" => s.season_count,
      "total_watch_time" => s.total_watch_time,
      "total_episodes" => total,
      "watched_episodes" => watched
    )
  end

  def next_up_for(s)
    last_watched = s.episodes.watched.order(season_number: :desc, episode_number: :desc).first

    if last_watched
      nxt = s.episodes.unwatched
        .where("season_number > ? OR (season_number = ? AND episode_number > ?)",
               last_watched.season_number, last_watched.season_number, last_watched.episode_number)
        .order(:season_number, :episode_number)
        .first
      return nxt if nxt
    end

    # Fallback: first unwatched
    s.episodes.unwatched.order(:season_number, :episode_number).first
  end
end
