class PendingImport < ApplicationRecord
  STATUSES = %w[pending confirmed ignored failed].freeze
  KINDS = %w[shows movies].freeze

  belongs_to :media_folder

  serialize :candidates, coder: JSON

  validates :folder_path, presence: true, uniqueness: true
  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :pending, -> { where(status: "pending") }
end
