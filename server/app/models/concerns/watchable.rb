# Shared logic for models that track watch progress.
# Expects columns: watched (integer 0/1), progress_seconds, duration_seconds, last_watched_at
module Watchable
  extend ActiveSupport::Concern

  WATCHED_THRESHOLD = 0.9

  included do
    scope :watched,   -> { where(watched: 1) }
    scope :unwatched, -> { where(watched: 0) }
  end

  def watched?
    watched == 1
  end

  def mark_watched!
    update!(watched: 1, last_watched_at: Time.current)
  end

  def mark_unwatched!
    update!(watched: 0, progress_seconds: 0, last_watched_at: nil)
  end

  def update_progress!(progress, duration)
    update!(
      progress_seconds: progress,
      duration_seconds: duration,
      last_watched_at: Time.current
    )
  end

  # Calculate the time to resume playback from.
  # Returns 0 if no meaningful progress or already past 90%.
  def resume_time
    return 0 unless progress_seconds > 0 && duration_seconds > 0
    return 0 if progress_seconds.to_f / duration_seconds >= WATCHED_THRESHOLD

    progress_seconds
  end
end
