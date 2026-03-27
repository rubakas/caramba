# Scans a series' media directory for season folders and episode files,
# then upserts them into the episodes table scoped to that series.
#
# Supports any show that follows the standard SxxExx naming convention:
#   Show.Name.S01E01.Episode.Title.1080p.WEBRip.x265.mkv
#
# Can also auto-detect the series name from the root folder:
#   "The.Simpsons.1989.WEBRip.BDRip.H.265-ernzarob" -> "The Simpsons"
class MediaScanner
  SEASON_PATTERN  = /\.S(\d+)\./i
  EPISODE_PATTERN = /\.S(\d+)E(\d+)\.(.+?)\.(?:\d+p)/i

  def self.scan!(series)
    new(series).scan!
  end

  # Create or find a Series from a folder path, auto-detecting the name,
  # then scan its episodes and fetch metadata from TVMaze.
  # Returns the Series record.
  def self.add_from_path!(path)
    path = path.strip
    name = Series.name_from_path(path)
    series = Series.find_or_initialize_by(media_path: path)
    series.name = name if series.new_record?
    series.save!
    scan!(series)
    MetadataFetcher.fetch!(series)
    series.reload
  end

  def initialize(series)
    @series = series
    @media_root = series.media_path
  end

  def scan!
    unless Dir.exist?(@media_root)
      Rails.logger.warn("MediaScanner: media root not found: #{@media_root}")
      return 0
    end

    count = 0

    season_dirs.each do |dir|
      season_num = parse_season_number(dir)
      next unless season_num

      season_path = File.join(@media_root, dir)
      mkv_files(season_path).each do |filename|
        ep = parse_episode(filename)
        next unless ep

        full_path = File.join(season_path, filename)
        episode = @series.episodes.find_or_initialize_by(code: ep[:code])
        episode.assign_attributes(
          season_number: ep[:season],
          episode_number: ep[:episode],
          title: ep[:title],
          file_path: full_path
        )
        episode.save! if episode.new_record? || episode.changed?
        count += 1
      end
    end

    Rails.logger.info("MediaScanner: scanned #{count} episodes for '#{@series.name}'")
    count
  end

  private

  def season_dirs
    Dir.entries(@media_root)
       .select { |d| File.directory?(File.join(@media_root, d)) && d.match?(SEASON_PATTERN) }
       .sort_by { |d| parse_season_number(d) || 0 }
  end

  def mkv_files(path)
    Dir.entries(path)
       .select { |f| f.end_with?('.mkv') }
       .sort
  end

  def parse_season_number(folder_name)
    match = folder_name.match(SEASON_PATTERN)
    match ? match[1].to_i : nil
  end

  def parse_episode(filename)
    match = filename.match(EPISODE_PATTERN)
    return nil unless match

    season  = match[1].to_i
    episode = match[2].to_i
    title   = match[3].tr('.', ' ')
    code    = format('S%02dE%02d', season, episode)

    { season: season, episode: episode, title: title, code: code }
  end
end
