class Api::HistoryController < Api::BaseController
  # GET /api/history
  def index
    limit = (params[:limit] || 100).to_i
    records = WatchHistory
      .joins(episode: :series)
      .select(
        "watch_histories.*",
        "episodes.code",
        "episodes.title AS episode_title",
        "episodes.season_number",
        "episodes.episode_number",
        "series.name AS series_name",
        "series.slug AS series_slug",
        "series.poster_url AS series_poster"
      )
      .order(started_at: :desc)
      .limit(limit)

    render json: records.map(&:attributes)
  end

  # GET /api/history/stats
  def stats
    render json: {
      total_time: WatchHistory.sum(:progress_seconds) || 0,
      total_episodes: WatchHistory.distinct.count(:episode_id),
      total_series: WatchHistory
        .joins(:episode)
        .select("DISTINCT episodes.series_id")
        .count
    }
  end
end
