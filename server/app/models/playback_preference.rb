class PlaybackPreference < ApplicationRecord
  belongs_to :show, optional: true
  belongs_to :movie, optional: true

  validates :show_id, uniqueness: true, allow_nil: true
  validates :movie_id, uniqueness: true, allow_nil: true
  validate :show_or_movie_present

  private

  def show_or_movie_present
    if show_id.blank? && movie_id.blank?
      errors.add(:base, "must belong to a show or a movie")
    end
    if show_id.present? && movie_id.present?
      errors.add(:base, "cannot belong to both a show and a movie")
    end
  end
end
