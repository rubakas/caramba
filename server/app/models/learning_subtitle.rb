class LearningSubtitle < ApplicationRecord
  belongs_to :media, polymorphic: true

  validates :stream_index, presence: true, uniqueness: { scope: [ :media_type, :media_id ] }
  validates :format, presence: true, inclusion: { in: %w[srt vtt ass] }
  validates :path, presence: true
  validates :extracted_at, presence: true
end
