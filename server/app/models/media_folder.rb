class MediaFolder < ApplicationRecord
  KINDS = %w[shows movies].freeze

  has_many :pending_imports, dependent: :destroy

  before_validation :normalize_path

  validates :path, presence: true, uniqueness: { scope: :kind }
  validates :kind, presence: true, inclusion: { in: KINDS }
  validate :path_must_be_absolute
  validate :path_must_exist_on_disk

  scope :enabled, -> { where(enabled: true) }

  private

  def normalize_path
    return if path.blank?
    stripped = path.to_s.strip
    self.path = (stripped == "/" ? stripped : stripped.chomp("/"))
  end

  def path_must_be_absolute
    return if path.blank?
    errors.add(:path, "must be an absolute path") unless Pathname.new(path).absolute?
  end

  def path_must_exist_on_disk
    return if path.blank?
    errors.add(:path, "does not exist or is not a directory") unless Dir.exist?(path)
  end
end
