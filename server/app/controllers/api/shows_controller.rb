class Api::ShowsController < Api::BaseController
  # GET /api/shows
  def index
    shows = Show.all.order(:name)
    render json: shows.map { |s| show_with_counts(s) }
  end

  # GET /api/shows/:slug
  def show
    s = Show.find_by!(slug: params[:slug])
    render json: show_with_counts(s)
  end

  # GET /api/shows/:slug/full
  # Combined handler: returns everything Show page needs in one request.
  def full
    s = Show.find_by!(slug: params[:slug])
    eps = s.episodes.ordered
    seasons = s.episodes.distinct.pluck(:season_number).compact.sort

    # Attach download status to each episode
    downloads = Download.where(episode_id: eps.map(&:id))
    dl_by_episode = downloads.index_by(&:episode_id)

    episodes_json = eps.map do |ep|
      ep.as_json.merge("download" => dl_by_episode[ep.id]&.as_json)
    end

    render json: {
      show: show_with_counts(s),
      episodes: episodes_json,
      seasons: seasons,
      continue: continue_for(s)
    }
  end

  # GET /api/shows/:slug/episodes
  def episodes
    s = Show.find_by!(slug: params[:slug])
    render json: s.episodes.ordered
  end

  # GET /api/shows/:slug/seasons
  def seasons
    s = Show.find_by!(slug: params[:slug])
    render json: s.episodes.distinct.pluck(:season_number).compact.sort
  end

  # GET /api/shows/:slug/continue
  def continue
    s = Show.find_by!(slug: params[:slug])
    render json: continue_for(s)
  end

  # POST /api/shows
  # Server-side equivalent of addShow — scans folder, fetches metadata
  def create
    folder_path = params[:folder_path]&.strip
    return render(json: { error: "folder_path required" }, status: :unprocessable_entity) unless folder_path.present?

    name = MediaScannerService.name_from_path(folder_path)
    s = Show.find_by(media_path: folder_path) || Show.create!(name: name, media_path: folder_path)

    MediaScannerService.scan(s)
    TvmazeService.fetch_for_show(s)

    render json: show_with_counts(s.reload), status: :created
  end

  # POST /api/shows/:slug/scan
  def scan
    s = Show.find_by!(slug: params[:slug])
    count = MediaScannerService.scan(s)
    render json: { scanned: count }
  end

  # POST /api/shows/:slug/refresh_metadata
  def refresh_metadata
    s = Show.find_by!(slug: params[:slug])
    result = TvmazeService.fetch_for_show(s)
    render json: { success: result }
  end

  # DELETE /api/shows/:slug
  def destroy
    s = Show.find_by!(slug: params[:slug])
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

  def show_with_counts(s)
    total = s.episodes.count
    watched = s.episodes.watched.count
    mode = continue_for(s)[:mode]
    s.as_json.merge(
      "poster_url" => poster_url_for(s),
      "season_count" => s.season_count,
      "total_watch_time" => s.total_watch_time,
      "total_episodes" => total,
      "watched_episodes" => watched,
      "has_continue" => mode == "resume" || mode == "next"
    )
  end

  # Returns { mode:, episode: } for the unified "Continue Watching" CTA.
  # See docs/superpowers/specs/2026-04-18-unified-continue-cta-design.md.
  def continue_for(s)
    last_played = s.episodes.where.not(last_watched_at: nil)
      .order(last_watched_at: :desc).first

    if last_played
      return { mode: "resume", episode: last_played } unless episode_finished?(last_played)
      nxt = episode_after(last_played)
      return nxt ? { mode: "next", episode: nxt } : { mode: "done", episode: nil }
    end

    highest_watched = s.episodes.watched
      .order(season_number: :desc, episode_number: :desc).first
    if highest_watched
      nxt = episode_after(highest_watched)
      return nxt ? { mode: "next", episode: nxt } : { mode: "done", episode: nil }
    end

    first = s.episodes.ordered.first
    first ? { mode: "start", episode: first } : { mode: "empty", episode: nil }
  end

  def episode_after(ep)
    ep.show.episodes
      .where("season_number > ? OR (season_number = ? AND episode_number > ?)",
             ep.season_number, ep.season_number, ep.episode_number)
      .order(:season_number, :episode_number)
      .first
  end

  def episode_finished?(ep)
    return true if ep.watched == 1
    return false unless ep.duration_seconds.to_i > 0
    ep.progress_seconds.to_f / ep.duration_seconds >= Watchable::WATCHED_THRESHOLD
  end
end
