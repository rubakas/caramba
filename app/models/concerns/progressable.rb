# Shared progress tracking logic for Episode and WatchHistory.
# Both models have progress_seconds and duration_seconds columns.
module Progressable
  extend ActiveSupport::Concern

  COMPLETION_THRESHOLD = 0.9 # 90% watched = considered finished

  def progress_percent
    return 0 unless progress_seconds && duration_seconds && duration_seconds > 0

    [(progress_seconds * 100.0 / duration_seconds).round, 100].min
  end

  def in_progress?
    progress_seconds.to_i > 0 && !finished?
  end

  def finished?
    return false unless progress_seconds && duration_seconds && duration_seconds > 0

    progress_seconds >= (duration_seconds * COMPLETION_THRESHOLD)
  end

  def formatted_progress
    return nil unless progress_seconds&.positive?

    "#{ApplicationHelper.format_time(progress_seconds)} / #{ApplicationHelper.format_time(duration_seconds || 0)}"
  end
end
