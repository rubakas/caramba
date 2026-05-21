# Scans a show's media directory for episode files.
# Supports season subdirs, flat structures, and one-level-deep release folders.
# Mirrored in desktop/electron/services/media-scanner.js
#
# Filename + episode parsing is delegated to FilenameParserService (the
# Jellyfin-style chained parser). Public methods preserved for callers:
#   .name_from_path(folder)
#   .scan(show)
#   .parse_episode(filename)
#   .collect_video_files(media_root)

class MediaScannerService
  class << self
    # Derive a clean show name from a folder path.
    def name_from_path(folder_path)
      folder = File.basename(folder_path.to_s)
      parsed = FilenameParserService.parse(folder)
      title = parsed[:title]
      return title if title.present? && title != folder

      folder.tr(".", " ").strip.presence || folder
    end

    # Scan a show and upsert episodes. Returns count of scanned episodes.
    def scan(show)
      unless show.media_path.present? && Dir.exist?(show.media_path)
        Rails.logger.warn("MediaScanner: media root not found: #{show.media_path}")
        return 0
      end

      files = collect_video_files(show.media_path)
      count = 0

      files.each do |full_path, filename|
        parsed = FilenameParserService.parse(filename)
        next if parsed[:is_extra]
        next unless parsed[:type] == :episode && parsed[:episode]

        season = parsed[:season] || season_from_path(full_path) || 1
        episode_num = parsed[:episode]
        code = format("S%02dE%02d", season, episode_num)

        episode = Episode.find_or_initialize_by(show_id: show.id, code: code)
        episode.season_number = season
        episode.episode_number = episode_num
        episode.file_path = full_path
        if episode.tvmaze_id.blank? || episode.title.blank? || episode.title == code
          episode.title = extract_title_after_code(filename) || code
        end
        episode.save!
        TechProbeJob.perform_later(episode) if defined?(TechProbeJob)
        count += 1
      end

      Rails.logger.info("MediaScanner: scanned #{count} episodes for '#{show.name}'")
      count
    end

    # Parse episode info from filename. Returns hash or nil.
    # Kept for backwards compat with existing tests.
    def parse_episode(filename)
      parsed = FilenameParserService.parse(filename)
      return nil unless parsed[:type] == :episode && parsed[:episode]

      season = parsed[:season] || 1
      episode = parsed[:episode]
      code = format("S%02dE%02d", season, episode)
      title = extract_title_after_code(filename) || code

      { season: season, episode: episode, title: title, code: code }
    end

    # Collect all video files from a media root, handling season dirs +
    # release-folder nesting one level deep.
    def collect_video_files(media_root)
      files = collect_from_dir(media_root)

      if files.empty?
        safe_entries(media_root).each do |entry|
          next if entry.start_with?(".")
          subdir = File.join(media_root, entry)
          next unless File.directory?(subdir)
          next if season_dir?(entry)

          files.concat(collect_from_dir(subdir))
        end
      end

      files.sort_by { |_path, filename| filename }
    end

    # Backwards-compat alias for older callers.
    def collect_mkv_files(media_root)
      collect_video_files(media_root)
    end

    private

    def season_dir?(name)
      !FilenameParserService.season_from_folder(name).nil?
    end

    def collect_from_dir(dir)
      files = []
      entries = safe_entries(dir)

      entries.each do |entry|
        next if entry.start_with?(".")
        dir_path = File.join(dir, entry)
        next unless File.directory?(dir_path)
        next unless season_dir?(entry)

        safe_entries(dir_path).each do |f|
          full = File.join(dir_path, f)
          if FilenameParserService.video_file?(f) && File.file?(full)
            files << [ full, f ]
          end
        end
      end

      entries.each do |f|
        full = File.join(dir, f)
        if FilenameParserService.video_file?(f) && File.file?(full)
          files << [ full, f ]
        end
      end

      files
    end

    def safe_entries(dir)
      Dir.entries(dir) - %w[. ..]
    rescue SystemCallError
      []
    end

    # Best-effort season number from the parent directory of the file.
    def season_from_path(full_path)
      parent = File.basename(File.dirname(full_path))
      FilenameParserService.season_from_folder(parent)
    end

    # Extract a human episode title from the part of the filename after
    # the SxxExx code. Independent of FilenameParserService — that one
    # parses identifiers, this one extracts the episode title for display.
    def extract_title_after_code(filename)
      base = filename.sub(/\.\w+\z/, "")
      m = base.match(/S(\d{1,3})E(\d{1,3})/i)
      return nil unless m
      after_code = base[m.end(0)..]

      if after_code.match?(/\A\s*-\s*/)
        title = after_code.sub(/\A\s*-\s*/, "")
        title = title.sub(/\s*\([^)]*\)\s*\z/, "")
        return title.strip.presence
      end

      if after_code.match?(/\A\./)
        title = after_code.sub(/\A\./, "")
        title = title.sub(/\.(?:\d{3,4}p|WEB[-.]?DL|WEBRip|BluRay|BDRip|BDRemux|HDTV|DVDRip|AMZN|REPACK).*\z/i, "")
        title = title.tr(".", " ").strip
        return nil if title.match?(/\A\d{3,4}p\z/i)
        return title.presence
      end

      nil
    end
  end
end
