class WatchHistory < ApplicationRecord
  belongs_to :episode

  has_one :series, through: :episode

  def update_progress!(progress, duration)
    update!(
      progress_seconds: progress,
      duration_seconds: duration,
      ended_at: Time.current
    )
  end
end
