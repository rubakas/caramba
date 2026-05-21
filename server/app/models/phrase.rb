class Phrase < ApplicationRecord
  CLIP_STATUSES = %w[pending ready failed].freeze

  belongs_to :lesson

  validates :position,  presence: true, uniqueness: { scope: :lesson_id }
  validates :phrase,    presence: true
  validates :start_ms,  presence: true, numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :end_ms,    presence: true, numericality: { greater_than: 0, only_integer: true }
  validates :clip_status, inclusion: { in: CLIP_STATUSES }
  validate  :end_after_start

  def duration_ms
    end_ms - start_ms
  end

  private

  def end_after_start
    return if start_ms.blank? || end_ms.blank?
    errors.add(:end_ms, "must be greater than start_ms") unless end_ms > start_ms
  end
end
