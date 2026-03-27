class Episode < ApplicationRecord
  has_many :watch_histories, dependent: :destroy

  validates :code, presence: true, uniqueness: true
  validates :season_number, :episode_number, :title, :file_path, presence: true

  scope :watched, -> { where(watched: true) }
  scope :unwatched, -> { where(watched: false) }
  scope :by_order, -> { order(:season_number, :episode_number) }
  scope :for_season, ->(num) { where(season_number: num) }

  def self.last_watched
    watched.order(last_watched_at: :desc).first
  end

  def self.next_episode
    last = last_watched
    return by_order.first unless last

    by_order.where(
      'season_number > :s OR (season_number = :s AND episode_number > :e)',
      s: last.season_number, e: last.episode_number
    ).first
  end

  # Find the most recently played episode that wasn't finished (has progress but < 90%).
  # Returns nil if there's nothing to resume.
  def self.resumable
    where('progress_seconds > 0 AND duration_seconds > 0')
      .where('CAST(progress_seconds AS REAL) / duration_seconds < 0.9')
      .order(last_watched_at: :desc)
      .first
  end

  def self.grouped_by_season
    by_order.group_by(&:season_number)
  end

  def mark_watched!
    update!(watched: true, last_watched_at: Time.current)
  end

  def mark_unwatched!
    update!(watched: false, last_watched_at: nil)
  end

  def progress_percent
    return 0 unless progress_seconds && duration_seconds && duration_seconds > 0

    [(progress_seconds * 100.0 / duration_seconds).round, 100].min
  end

  def in_progress?
    progress_seconds.to_i > 0 && !finished?
  end

  def finished?
    return false unless progress_seconds && duration_seconds && duration_seconds > 0

    progress_seconds >= (duration_seconds * 0.9)
  end

  def formatted_progress
    return nil unless progress_seconds&.positive?

    "#{format_time(progress_seconds)} / #{format_time(duration_seconds || 0)}"
  end

  private

  def format_time(seconds)
    mins, secs = seconds.divmod(60)
    hours, mins = mins.divmod(60)
    if hours > 0
      format('%d:%02d:%02d', hours, mins, secs)
    else
      format('%d:%02d', mins, secs)
    end
  end
end
