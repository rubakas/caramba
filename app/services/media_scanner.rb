# Scans the media root directory for Simpsons season folders and episode files,
# then upserts them into the episodes table.
class MediaScanner
  MEDIA_ROOT = ENV.fetch('SIMPSONS_MEDIA_PATH',
                         '/Volumes/Mac Backup/The.Simpsons.1989.WEBRip.BDRip.H.265-ernzarob')

  SEASON_PATTERN = /\.S(\d+)\./
  EPISODE_PATTERN = /\.S(\d+)E(\d+)\.(.+?)\.(?:\d+p)/

  def self.scan!
    new.scan!
  end

  def scan!
    unless Dir.exist?(MEDIA_ROOT)
      Rails.logger.warn("MediaScanner: media root not found: #{MEDIA_ROOT}")
      return 0
    end

    count = 0

    season_dirs.each do |dir|
      season_num = parse_season_number(dir)
      next unless season_num

      season_path = File.join(MEDIA_ROOT, dir)
      mkv_files(season_path).each do |filename|
        ep = parse_episode(filename)
        next unless ep

        full_path = File.join(season_path, filename)
        episode = Episode.find_or_initialize_by(code: ep[:code])
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

    Rails.logger.info("MediaScanner: scanned #{count} episodes")
    count
  end

  private

  def season_dirs
    Dir.entries(MEDIA_ROOT)
       .select { |d| File.directory?(File.join(MEDIA_ROOT, d)) && d.match?(SEASON_PATTERN) }
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

    season = match[1].to_i
    episode = match[2].to_i
    title = match[3].tr('.', ' ')
    code = format('S%02dE%02d', season, episode)

    { season: season, episode: episode, title: title, code: code }
  end
end
