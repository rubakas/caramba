# Scans a series' media directory for episode files,
# then upserts them into the episodes table scoped to that series.
#
# Supports multiple common naming conventions:
#
# Dot-separated (scene):
#   Show.Name.S01E01.Episode.Title.1080p.WEBRip.x265.mkv
#
# Space + hyphen (Plex-style):
#   Black Books (2000) - S01E01 - Cooking the Books (576p DVD x265 Ghost).mkv
#   The Sopranos (1999) - S01E01 - The Sopranos (1080p BluRay x265 ImE).mkv
#
# Folder structures supported:
#   - Season subdirs: "Season 1/", "Season 01/", ".S01."-containing dirs
#   - Flat: MKV files directly in root folder
class MediaScanner
  # Matches SxxExx anywhere in a filename (dot, space, or hyphen delimited)
  EPISODE_CODE_PATTERN = /S(\d{1,2})E(\d{1,2})/i

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

    # Collect all MKV files: from season subdirs and from root
    all_mkv_files = collect_mkv_files

    all_mkv_files.each do |full_path, filename|
      ep = parse_episode(filename)
      next unless ep

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

    Rails.logger.info("MediaScanner: scanned #{count} episodes for '#{@series.name}'")
    count
  end

  private

  # Collect [full_path, filename] pairs from all season dirs + root
  def collect_mkv_files
    files = []

    # Season subdirs: "Season 1", "Season 01", or dirs containing ".S01."
    Dir.entries(@media_root).each do |entry|
      dir_path = File.join(@media_root, entry)
      next unless File.directory?(dir_path)
      next if entry.start_with?('.')
      next unless season_dir?(entry)

      Dir.entries(dir_path).each do |f|
        next unless f.downcase.end_with?('.mkv')

        files << [File.join(dir_path, f), f]
      end
    end

    # Also check root for MKV files (flat structure like City and the City)
    Dir.entries(@media_root).each do |f|
      full = File.join(@media_root, f)
      next unless File.file?(full) && f.downcase.end_with?('.mkv')

      files << [full, f]
    end

    files.sort_by { |_, name| name }
  end

  # Recognise season directories in various formats:
  #   "Season 1", "Season 01", "Season1"
  #   "S01", ".S01.", "Specials"
  #   Any dir containing ".S<num>." in its name
  def season_dir?(name)
    name.match?(/\Aseason\s*\d+\z/i) ||
      name.match?(/\AS\d+\z/i) ||
      name.match?(/\.S\d+\./i) ||
      name.match?(/\Aspecials?\z/i)
  end

  # Parse episode info from a filename.
  # Handles both dot-separated and space/hyphen-separated naming.
  def parse_episode(filename)
    match = filename.match(EPISODE_CODE_PATTERN)
    return nil unless match

    season  = match[1].to_i
    episode = match[2].to_i
    code    = format('S%02dE%02d', season, episode)
    title   = extract_title(filename, match)

    { season: season, episode: episode, title: title || code, code: code }
  end

  # Extract a clean episode title from the filename.
  #
  # Dot-separated:  "The.Simpsons.S01E01.Simpsons.Roasting.on.an.Open.Fire.1080p.mkv"
  #   -> title is between "S01E01." and ".1080p" (dots become spaces)
  #
  # Hyphen-separated: "Black Books (2000) - S01E01 - Cooking the Books (576p DVD x265 Ghost).mkv"
  #   -> title is between "S01E01 - " and " (" (the quality parenthetical)
  def extract_title(filename, code_match)
    after_code = filename[code_match.end(0)..]

    # Try hyphen-separated: " - Title (quality).mkv" or " - Title.mkv"
    if after_code.match?(/\A\s*-\s*/)
      title = after_code.sub(/\A\s*-\s*/, '') # strip leading " - "
      title = title.sub(/\s*\([^)]*\)\s*\.mkv\z/i, '') # strip trailing "(quality).mkv"
      title = title.sub(/\.mkv\z/i, '') # strip .mkv if no parenthetical
      return title.strip.presence
    end

    # Try dot-separated: ".Title.Here.1080p..." or ".Title.Here.WEB-DL..."
    if after_code.match?(/\A\./)
      title = after_code.sub(/\A\./, '')
      title = title.sub(/\.(?:\d{3,4}p|WEB[-.]?DL|WEBRip|BluRay|BDRip|BDRemux|HDTV|DVDRip|AMZN|REPACK).*\z/i, '')
      title = title.tr('.', ' ').strip
      # If what remains is itself a quality tag (no real title), discard it
      title = nil if title.match?(/\A\d{3,4}p\z/i)
      return title.presence
    end

    nil
  end
end
