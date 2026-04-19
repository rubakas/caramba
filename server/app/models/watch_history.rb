class WatchHistory < ApplicationRecord
  belongs_to :episode

  has_one :show, through: :episode

  def update_progress!(progress, duration)
    update!(
      progress_seconds: progress,
      duration_seconds: duration,
      ended_at: Time.current
    )
  end
end
