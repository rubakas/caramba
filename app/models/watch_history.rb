class WatchHistory < ApplicationRecord
  belongs_to :episode

  scope :recent, -> { order(started_at: :desc) }
  scope :today, -> { where(started_at: Time.current.beginning_of_day..) }
  scope :this_week, -> { where(started_at: 1.week.ago..) }

  def finished?
    return false unless progress_seconds && duration_seconds && duration_seconds > 0

    progress_seconds >= (duration_seconds * 0.9) # 90% = considered finished
  end

  def progress_percent
    return 0 unless progress_seconds && duration_seconds && duration_seconds > 0

    [(progress_seconds * 100.0 / duration_seconds).round, 100].min
  end
end
