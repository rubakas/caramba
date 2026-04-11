class PlaybackPreference < ApplicationRecord
  belongs_to :series, optional: true
  belongs_to :movie, optional: true

  validates :series_id, uniqueness: true, allow_nil: true
  validates :movie_id, uniqueness: true, allow_nil: true
  validate :series_or_movie_present

  private

  def series_or_movie_present
    if series_id.blank? && movie_id.blank?
      errors.add(:base, "must belong to a series or a movie")
    end
    if series_id.present? && movie_id.present?
      errors.add(:base, "cannot belong to both a series and a movie")
    end
  end
end
