class HistoryController < ApplicationController
  def index
    @histories = WatchHistory.includes(:episode).recent.limit(100)
    @today = @histories.select { |h| h.started_at >= Time.current.beginning_of_day }
    @this_week = @histories.select { |h| h.started_at >= 1.week.ago && h.started_at < Time.current.beginning_of_day }
    @older = @histories - @today - @this_week

    @total_time = WatchHistory.sum(:progress_seconds) || 0
    @total_episodes = WatchHistory.select(:episode_id).distinct.count
  end
end
