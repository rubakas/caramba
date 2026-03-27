class Series < ApplicationRecord
  has_many :episodes, dependent: :destroy
  has_many :watch_histories, through: :episodes

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true
  validates :media_path, presence: true

  before_validation :generate_slug, if: -> { slug.blank? && name.present? }

  scope :by_name, -> { order(:name) }

  # Derive a clean series name from a folder path.
  # e.g. "/Volumes/Backup/The.Simpsons.1989.WEBRip.BDRip.H.265-ernzarob" -> "The Simpsons"
  # e.g. "/data/Breaking.Bad.2008.1080p.BluRay.x265" -> "Breaking Bad"
  # e.g. "/Volumes/NTFS/Black Books (2000) Season 1-3..." -> "Black Books"
  # e.g. "/Volumes/NTFS/The Sopranos" -> "The Sopranos"
  # e.g. "/Volumes/NTFS/The.City.And.The.City.S01.1080p..." -> "The City And The City"
  def self.name_from_path(path)
    folder = File.basename(path)
    # Strip parenthesized year and everything after: "Black Books (2000) Season..." -> "Black Books"
    clean = folder.sub(/\s*\(\d{4}\).*/, '')
    # Strip dot-separated year and everything after: "The.Simpsons.1989..." -> "The.Simpsons"
    clean = clean.sub(/[.](?:19|20)\d{2}.*/, '') if clean == folder
    # Strip season code and everything after: "The.City.And.The.City.S01.1080p..." -> "The.City.And.The.City"
    clean = clean.sub(/[.\s]S\d+.*/i, '') if clean == folder
    # Replace dots with spaces
    clean = clean.tr('.', ' ').strip
    clean.presence || folder
  end

  def total_episodes
    episodes.count
  end

  def watched_episodes
    episodes.watched.count
  end

  def progress_percent
    total = total_episodes
    return 0 if total.zero?

    (watched_episodes * 100.0 / total).round
  end

  def last_watched_episode
    episodes.watched.order(last_watched_at: :desc).first
  end

  def next_episode
    last = last_watched_episode
    return episodes.by_order.first unless last

    episodes.by_order.where(
      'season_number > :s OR (season_number = :s AND episode_number > :e)',
      s: last.season_number, e: last.episode_number
    ).first
  end

  def resumable_episode
    episodes
      .where('progress_seconds > 0 AND duration_seconds > 0')
      .where('CAST(progress_seconds AS REAL) / duration_seconds < 0.9')
      .order(last_watched_at: :desc)
      .first
  end

  def total_watch_time
    watch_histories.sum(:progress_seconds) || 0
  end

  def season_count
    episodes.distinct.count(:season_number)
  end

  # Metadata helpers

  def genres_list
    return [] if genres.blank?

    genres.split(',').map(&:strip).reject(&:blank?)
  end

  def premiere_year
    premiered&.slice(0, 4)
  end

  def has_metadata?
    tvmaze_id.present?
  end

  def has_poster?
    poster_url.present?
  end

  private

  def generate_slug
    self.slug = name.parameterize
  end
end
