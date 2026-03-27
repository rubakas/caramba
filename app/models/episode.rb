class Episode < ApplicationRecord
  include Progressable

  belongs_to :series
  has_many :watch_histories, dependent: :destroy

  validates :code, presence: true, uniqueness: { scope: :series_id }
  validates :season_number, :episode_number, :title, :file_path, presence: true

  scope :watched, -> { where(watched: true) }
  scope :unwatched, -> { where(watched: false) }
  scope :by_order, -> { order(:season_number, :episode_number) }
  scope :for_season, ->(num) { where(season_number: num) }

  def self.grouped_by_season
    by_order.group_by(&:season_number)
  end

  def mark_watched!
    update!(watched: true, last_watched_at: Time.current)
  end

  def mark_unwatched!
    update!(watched: false, last_watched_at: nil)
  end
end
