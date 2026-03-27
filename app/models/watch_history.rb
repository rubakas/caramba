class WatchHistory < ApplicationRecord
  include Progressable

  belongs_to :episode
  has_one :series, through: :episode

  scope :recent, -> { order(started_at: :desc) }
  scope :today, -> { where(started_at: Time.current.beginning_of_day..) }
  scope :this_week, -> { where(started_at: 1.week.ago..) }
end
