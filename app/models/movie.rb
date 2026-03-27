class Movie < ApplicationRecord
  include Progressable

  validates :title, presence: true
  validates :slug, presence: true, uniqueness: true
  validates :file_path, presence: true, uniqueness: true

  before_validation :generate_slug, if: -> { slug.blank? && title.present? }

  scope :by_title, -> { order(:title) }
  scope :watched, -> { where(watched: true) }
  scope :unwatched, -> { where(watched: false) }
  scope :recently_watched, -> { watched.order(last_watched_at: :desc) }

  # Extract a clean movie name from a filename.
  # e.g. "Everything Everywhere All at Once (2022) BDRip 1080p H.265 [UKR_ENG] [Hurtom].mkv" -> "Everything Everywhere All at Once"
  # e.g. "Movie.Name.2022.1080p.BluRay.x265.mkv" -> "Movie Name"
  def self.name_from_filename(filename)
    name = File.basename(filename, File.extname(filename))

    # Strip parenthesized year and everything after
    clean = name.sub(/\s*\(\d{4}\).*/, '')
    return clean.strip if clean != name && clean.present?

    # Strip dot-separated year (19xx/20xx) and everything after
    clean = name.sub(/[.](?:19|20)\d{2}.*/, '')
    return clean.tr('.', ' ').strip if clean != name && clean.present?

    # Strip season/quality markers
    clean = name.sub(/[.\s](?:\d{3,4}p|WEB[-.]?DL|WEBRip|BluRay|BDRip|BDRemux|HDTV|DVDRip|AMZN).*\z/i, '')
    clean = clean.tr('.', ' ').strip
    clean.presence || name
  end

  # Extract year from filename if present
  def self.year_from_filename(filename)
    if filename =~ /\((\d{4})\)/
      ::Regexp.last_match(1)
    elsif filename =~ /[.\s]((?:19|20)\d{2})[.\s]/
      ::Regexp.last_match(1)
    end
  end

  def mark_watched!
    update!(watched: true, last_watched_at: Time.current)
  end

  def mark_unwatched!
    update!(watched: false, last_watched_at: nil, progress_seconds: 0)
  end

  def has_metadata?
    imdb_id.present? || description.present?
  end

  def has_poster?
    poster_url.present?
  end

  def genres_list
    return [] if genres.blank?

    genres.split(',').map(&:strip).reject(&:blank?)
  end

  def runtime_display
    return nil unless runtime&.positive?

    hours, mins = runtime.divmod(60)
    hours > 0 ? "#{hours}h #{mins}m" : "#{mins}m"
  end

  private

  def generate_slug
    base = title.parameterize
    base = "#{base}-#{year}" if year.present?
    self.slug = base
  end
end
