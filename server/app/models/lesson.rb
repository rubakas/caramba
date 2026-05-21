class Lesson < ApplicationRecord
  STATUSES = %w[pending generating ready failed].freeze
  PROVIDERS = %w[manual anthropic openai ollama].freeze

  belongs_to :episode, optional: true
  belongs_to :movie,   optional: true
  belongs_to :source_subtitle, class_name: "LearningSubtitle"

  has_many :phrases, -> { order(:position) }, dependent: :destroy

  validates :status,   inclusion: { in: STATUSES }
  validates :provider, inclusion: { in: PROVIDERS }
  validate  :exactly_one_media_target

  def media
    episode || movie
  end

  private

  def exactly_one_media_target
    set = [ episode_id, movie_id ].compact
    if set.empty?
      errors.add(:base, "must reference an episode or a movie")
    elsif set.size > 1
      errors.add(:base, "cannot reference both an episode and a movie")
    end
  end
end
