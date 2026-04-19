class Episode < ApplicationRecord
  include Watchable

  belongs_to :show
  has_many :watch_histories, dependent: :destroy
  has_many :downloads, dependent: :destroy

  validates :code, presence: true, uniqueness: { scope: :show_id }

  scope :for_season, ->(season) { where(season_number: season).order(:episode_number) }
  scope :ordered, -> { order(:season_number, :episode_number) }

  # Mark all episodes before this one (by season/episode number) as watched
  def self.mark_prior_watched!(show_id, season_number, episode_number)
    where(show_id: show_id)
      .where("season_number < ? OR (season_number = ? AND episode_number < ?)",
             season_number, season_number, episode_number)
      .where(watched: 0)
      .update_all(watched: 1, last_watched_at: Time.current)
  end

  # Next episode in show order (regardless of watched status)
  def next_episode
    show.episodes
      .where("season_number > ? OR (season_number = ? AND episode_number > ?)",
             season_number, season_number, episode_number)
      .order(:season_number, :episode_number)
      .first
  end
end
