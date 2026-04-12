# Scans a series' media directory for episode files (.mkv).
# Supports season subdirs, flat structures, and one-level-deep release folders.
# Ported from desktop/electron/services/media-scanner.js

class MediaScannerService
  EPISODE_CODE_RE = /S(\d{1,3})E(\d{1,3})/i

  # Quality/release markers used to strip titles
  RELEASE_MARKERS_RE = /\.(?:\d{3,4}p|WEB[-.]?DL|WEBRip|BluRay|BDRip|BDRemux|HDTV|DVDRip|AMZN|REPACK).*$/i

  class << self
    # Derive a clean series name from a folder path
    def name_from_path(folder_path)
      folder = File.basename(folder_path)
      clean = folder

      # Strip parenthesized year and everything after: "Black Books (2000) Season..." -> "Black Books"
      stripped = clean.sub(/\s*\(\d{4}\).*/, "")
      return stripped.strip if stripped != clean && stripped.strip.present?

      # Strip dot-separated year and everything after: "The.Simpsons.1989..." -> "The Simpsons"
      stripped = clean.sub(/[.](?:19|20)\d{2}.*/, "")
      if stripped != clean && stripped.strip.present?
        return stripped.tr(".", " ").strip
      end

      # Strip season code and everything after: "The.City.And.The.City.S01..." -> "The City And The City"
      stripped = clean.sub(/[.\s]S\d+.*/i, "")
      if stripped != clean && stripped.strip.present?
        return stripped.tr(".", " ").strip
      end

      result = clean.tr(".", " ").strip
      result.presence || folder
    end

    # Scan a series and upsert episodes. Returns count of scanned episodes.
    def scan(series)
      unless series.media_path.present? && Dir.exist?(series.media_path)
        Rails.logger.warn("MediaScanner: media root not found: #{series.media_path}")
        return 0
      end

      mkv_files = collect_mkv_files(series.media_path)
      count = 0

      mkv_files.each do |full_path, filename|
        ep = parse_episode(filename)
        next unless ep

        episode = Episode.find_or_initialize_by(series_id: series.id, code: ep[:code])
        episode.assign_attributes(
          title: ep[:title],
          season_number: ep[:season],
          episode_number: ep[:episode],
          file_path: full_path
        )
        episode.save!
        count += 1
      end

      Rails.logger.info("MediaScanner: scanned #{count} episodes for '#{series.name}'")
      count
    end

    # Parse episode info from filename. Returns hash or nil.
    def parse_episode(filename)
      match = filename.match(EPISODE_CODE_RE)
      return nil unless match

      season = match[1].to_i
      episode = match[2].to_i
      code = format("S%02dE%02d", season, episode)
      title = extract_title(filename, match) || code

      { season: season, episode: episode, title: title, code: code }
    end

    # Collect all MKV files from a media root, handling season dirs + release folder nesting
    def collect_mkv_files(media_root)
      files = collect_from_dir(media_root)

      if files.empty?
        # Look one level deeper for release folders
        safe_entries(media_root).each do |entry|
          next if entry.start_with?(".")
          subdir = File.join(media_root, entry)
          next unless File.directory?(subdir)
          next if season_dir?(entry)

          nested = collect_from_dir(subdir)
          if nested.any?
            files = nested
            break
          end
        end
      end

      files.sort_by { |_path, filename| filename }
    end

    private

    def season_dir?(name)
      name.match?(/\Aseason\s*\d+\z/i) ||
        name.match?(/\AS\d+\z/i) ||
        name.match?(/\.S\d+\./i) ||
        name.match?(/\Aspecials?\z/i)
    end

    def collect_from_dir(dir)
      files = []
      entries = safe_entries(dir)

      # Collect from season subdirs
      entries.each do |entry|
        next if entry.start_with?(".")
        dir_path = File.join(dir, entry)
        next unless File.directory?(dir_path)
        next unless season_dir?(entry)

        safe_entries(dir_path).each do |f|
          if f.downcase.end_with?(".mkv")
            files << [ File.join(dir_path, f), f ]
          end
        end
      end

      # Also check root for MKV files (flat structure)
      entries.each do |f|
        full = File.join(dir, f)
        if f.downcase.end_with?(".mkv") && File.file?(full)
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

    # Extract episode title from filename, after the S01E01 code
    def extract_title(filename, match)
      after_code = filename[match.end(0)..]

      # Hyphen-separated: " - Title (quality).mkv"
      if after_code.match?(/\A\s*-\s*/)
        title = after_code.sub(/\A\s*-\s*/, "")
        title = title.sub(/\s*\([^)]*\)\s*\.mkv\z/i, "")
        title = title.sub(/\.mkv\z/i, "")
        return title.strip.presence
      end

      # Dot-separated: ".Title.Here.1080p..."
      if after_code.match?(/\A\./)
        title = after_code.sub(/\A\./, "")
        title = title.sub(/\.mkv\z/i, "")
        title = title.sub(RELEASE_MARKERS_RE, "")
        title = title.tr(".", " ").strip
        return nil if title.match?(/\A\d{3,4}p\z/i)
        return title.presence
      end

      nil
    end
  end
end
