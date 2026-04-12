# Parses movie names and years from filenames.
# Ported from desktop/electron/services/movie-metadata.js (nameFromFilename, yearFromFilename)

class MovieParserService
  QUALITY_RE = /[.\s](?:\d{3,4}p|WEB[-.]?DL|WEBRip|BluRay|BDRip|BDRemux|HDTV|DVDRip|AMZN).*$/i

  class << self
    # Extract a clean movie name from a filename (strips path + extension first)
    def name_from_filename(filepath)
      name = File.basename(filepath, File.extname(filepath))

      # Strip parenthesized year and everything after
      clean = name.sub(/\s*\(\d{4}\).*/, "")
      return clean.strip if clean != name && clean.strip.present?

      # Strip dot-separated year (19xx/20xx) and everything after
      clean = name.sub(/[.](?:19|20)\d{2}.*/, "")
      if clean != name && clean.strip.present?
        return clean.tr(".", " ").strip
      end

      # Strip quality markers
      clean = name.sub(QUALITY_RE, "")
      clean = clean.tr(".", " ").strip
      clean.presence || name
    end

    # Extract year from filename
    def year_from_filename(filepath)
      filename = File.basename(filepath)

      # Parenthesized year: (2023)
      m = filename.match(/\((\d{4})\)/)
      return m[1] if m

      # Dot/space-separated year: .2023. or " 2023 "
      m = filename.match(/[.\s]((?:19|20)\d{2})[.\s]/)
      return m[1] if m

      nil
    end
  end
end
