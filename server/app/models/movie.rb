class Movie < ApplicationRecord
  include Watchable

  has_many :playback_preferences, dependent: :destroy
  has_many :downloads, dependent: :destroy

  validates :title, presence: true
  validates :slug, presence: true, uniqueness: true
  validates :file_path, uniqueness: true, allow_nil: true

  before_validation :generate_slug, on: :create

  private

  def generate_slug
    return if slug.present?
    return unless title.present?

    base = self.class.slugify(title + (year.present? ? "-#{year}" : ""))
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
