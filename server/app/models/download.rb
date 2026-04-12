class Download < ApplicationRecord
  belongs_to :episode, optional: true
  belongs_to :movie, optional: true

  validates :file_path, presence: true
  validates :status, presence: true, inclusion: { in: %w[pending downloading complete failed] }
  validates :episode_id, uniqueness: true, allow_nil: true
  validates :movie_id, uniqueness: true, allow_nil: true
  validate :episode_or_movie_present

  scope :complete, -> { where(status: "complete") }

  def self.total_size
    complete.sum(:file_size)
  end

  private

  def episode_or_movie_present
    if episode_id.blank? && movie_id.blank?
      errors.add(:base, "must belong to an episode or a movie")
    end
    if episode_id.present? && movie_id.present?
      errors.add(:base, "cannot belong to both an episode and a movie")
    end
  end
end
