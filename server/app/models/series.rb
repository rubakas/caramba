class Series < ApplicationRecord
  has_many :episodes, dependent: :destroy
  has_many :watch_histories, through: :episodes
  has_many :playback_preferences, dependent: :destroy
  has_many :downloads, through: :episodes

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true

  before_validation :generate_slug, on: :create

  def season_count
    episodes.distinct.count(:season_number)
  end

  def total_watch_time
    watch_histories.sum(:progress_seconds)
  end

  private

  def generate_slug
    return if slug.present?

    base = self.class.slugify(name)
    candidate = base
    counter = 1
    while self.class.exists?(slug: candidate)
      candidate = "#{base}-#{counter}"
      counter += 1
    end
    self.slug = candidate
  end

  def self.slugify(text)
    text.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
  end
end
