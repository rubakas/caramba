class Episode < ApplicationRecord
  belongs_to :series
  has_many :watch_histories, dependent: :destroy
  has_many :downloads, dependent: :destroy

  validates :code, presence: true, uniqueness: { scope: :series_id }

  scope :for_season, ->(season) { where(season_number: season).order(:episode_number) }
  scope :watched, -> { where(watched: 1) }
  scope :unwatched, -> { where(watched: 0) }
  scope :ordered, -> { order(:season_number, :episode_number) }

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

  # Next episode in series order (regardless of watched status)
  def next_episode
    series.episodes
      .where("season_number > ? OR (season_number = ? AND episode_number > ?)",
             season_number, season_number, episode_number)
      .order(:season_number, :episode_number)
      .first
  end
end
