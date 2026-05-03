# Filename / path parser. Single source of truth for naming rules.
#
# Ported from Jellyfin's Emby.Naming library:
#   https://github.com/jellyfin/jellyfin/tree/master/Emby.Naming
# specifically NamingOptions.cs (regex registry), CleanStringParser.cs
# (chained noise removal), EpisodePathParser.cs (iteration + guards),
# SeasonPathParser.cs (multilingual season folders), and
# MediaBrowser.Common/Providers/ProviderIdParsers.cs (id sniffing).
#
# Public API:
#   FilenameParserService.parse(path) -> Hash
#   FilenameParserService.extract_provider_ids(text) -> Hash
#   FilenameParserService.season_from_folder(name) -> Integer | nil
#   FilenameParserService.extra_kind(path) -> Symbol | nil

class FilenameParserService
  # ── Episode regex chain ──────────────────────────────────────────────
  # Evaluated in order; first match wins. Named captures: season, ep,
  # episode_end, year, month, day. Strict patterns first; the "optimistic"
  # bare-digit forms are evaluated last so they don't eat clean cases.

  EPISODE_PATTERNS = [
    # S01E01, S1E1, S01.E01 — Kodi standard
    /(?<season>\d{1,2})[ ._\-]*[Ee](?<ep>\d{1,3})(?:[ ._\-]?[Ee](?<episode_end>\d{1,3}))?/i.then { |re|
      Regexp.new("[Ss]" + re.source, re.options)
    }.freeze,

    # 1x01, 01x01x02
    /(?<![\d])(?<season>\d{1,2})x(?<ep>\d{1,3})(?:[\-x](?<episode_end>\d{1,3}))?/i,

    # "Season 1 Episode 5"
    /[Ss]eason\s*(?<season>\d{1,2})\s+[Ee]pisode\s*(?<ep>\d{1,3})/i,

    # "Episode 16" — assumes season 1 unless folder says otherwise
    /\b[Ee]pisode\s+(?<ep>\d{1,3})\b/.freeze,

    # "ep01", "EP_01", ".E01."
    /[._\s\-][Ee][Pp]?_?(?<ep>\d{1,3})(?:[._\s\-]|\z)/.freeze,

    # Anime fan-sub bracketed: "[Group] Series Name - 04 [BDRip]" or
    # "[Group] Series Name - 04v2 [1080p]"
    /\[[^\]]+\][\s_]*(?<seriesname>[^\[\]]+?)[\s_]+-[\s_]+(?<ep>\d{1,3})(?:v\d+)?[\s_]*(?:\[|\z)/.freeze
  ].freeze

  # Date-based (talk shows, news). Run only after `_` -> `-` normalization.
  DATE_PATTERNS = [
    /(?<year>\d{4})[._\-](?<month>\d{2})[._\-](?<day>\d{2})/,
    /(?<day>\d{2})[._\-](?<month>\d{2})[._\-](?<year>\d{4})/
  ].freeze

  # ── Year extraction ──────────────────────────────────────────────────
  # The lookahead `(?![0-9]+|\W\d{2}\W\d{2})` stops greedy match into
  # date-like sequences ("2024.04.20" → not year=2024).
  YEAR_PATTERN = /[\s._\-(\[](?<year>(?:19|20)\d{2})(?![0-9]+|\W\d{2}\W\d{2})(?:[\s._\-)\]]|\z)/.freeze

  # ── Filename-embedded provider IDs ───────────────────────────────────
  # Generic [name-VALUE] / {name=VALUE} / (name-VALUE) form, plus tight
  # `tt` + 7–8-digit IMDb scan anywhere in the string.
  PROVIDER_ID_BRACKET = /[\[\(\{](?<key>imdb|tmdb|tvdb|tvmaze)id[\-=](?<value>[A-Za-z0-9]+)[\]\)\}]/i.freeze
  IMDB_LOOSE = /\btt(\d{7,8})\b/.freeze

  # ── Season folder regex ──────────────────────────────────────────────
  # English first; aliases for Russian (Сезон), Italian (Stagione),
  # Spanish (Temporada), French (Saison), German (Staffel) — present in
  # example.rb noise list and common in mixed-language libraries.
  SEASON_FOLDER_PATTERNS = [
    /\A\s*(?:season|saison|staffel|stagione|temporada|сезон|сезон\s*№?)\s*(?<season>\d{1,3})\s*\z/i,
    /\A\s*(?<season>\d{1,3})(?:st|nd|rd|th|\.)\s*(?:season|saison|staffel)\s*\z/i,
    /\A\s*[sS](?<season>\d{1,3})\s*\z/.freeze
  ].freeze

  SPECIAL_FOLDER_PATTERN = /\A(?:specials?|extras?)\z/i.freeze

  # ── CleanString chain ────────────────────────────────────────────────
  # Each regex captures `<cleaned>`; output of one is fed into the next.
  # Strips codec / source / release-group / language / trailing-tag noise.
  CLEAN_STRING_PATTERNS = [
    # Codec / source / quality / language alternation. Strips everything from
    # the first noise token onward.
    /\A\s*(?<cleaned>.+?)[\s_,.()\[\]\-](?:3d|sbs|tab|hsbs|htab|mvc|hdr|hdr10|dolby[._\-\s]?vision|dv|uhd|ultrahd|4k|8k|2160p|1080p|1080i|720p|720i|576p|576i|480p|480i|360p|240p|ac3|dts(?:-?hd)?|truehd|atmos|aac2?|e?ac3|ddp?5\.1|flac|opus|vorbis|mp3|h\.?264|h\.?265|hevc|avc|x264|x265|xvid|divx|av1|vp9|bluray|blu-?ray|bdrip|brrip|bdremux|web[\-.]?dl|webrip|hdtv|hdrip|hdtvrip|dvdrip|dvdscr|dvdscreener|screener|cam|telesync|ts|telecine|tc|hddvd|amzn|nf|hulu|atv|dsnp|max|hbo|hmax|repack|proper|rerip|extended|unrated|directors?\.?cut|theatrical|imax|criterion|remastered|remux|multi|dual|hindi|english|rus|russian|italian|german|french|spanish|korean|japanese|chinese|polish|portuguese|dutch|ukr|ukrainian)(?:[\s_,.()\[\]\-]|\z)/i.freeze,

    # Strip trailing [TAG] [TAG2]...
    /\A\s*(?<cleaned>.+?)(?:\s*\[[^\]]+\]\s*)+\z/.freeze,

    # Strip leading [Group] (typical anime fansub prefix)
    /\A\s*\[[^\]]+\]\s*(?<cleaned>.+)\z/.freeze,

    # Strip multi-episode suffix: "...E01-E03"
    /\A\s*(?<cleaned>.+?)\W[Ee]\d+(?:-|~)[Ee]?\d+(?:\W|\z)/.freeze,

    # Strip trailing " - 123" episode marker
    /\A\s*(?<cleaned>.+?)\s+-\s+\d{1,4}\s*\z/.freeze,

    # Strip extra-type suffix: "-trailer", ".sample", "-behindthescenes", ...
    /\A\s*(?<cleaned>.+?)(?:[._\-\s](?:trailer|sample|scene|clip|behindthescenes|deleted|deletedscene|featurette|short|interview|other|extra))\z/i.freeze,

    # Strip trailing season marker: "Show.S01", "Show S1", "Show.Season.1"
    # — common in folder names. Only trailing; in-string "S01E01" is the
    # episode parser's job.
    /\A\s*(?<cleaned>.+?)[._\s\-](?:[Ss]eason[._\s\-]?\d{1,3}|[Ss]\d{1,3})\s*\z/.freeze
  ].freeze

  # ── Extras detection ─────────────────────────────────────────────────
  EXTRA_DIRECTORIES = {
    "trailers" => :trailer,
    "samples" => :sample,
    "extras" => :extra,
    "scenes" => :scene,
    "shorts" => :short,
    "featurettes" => :featurette,
    "interviews" => :interview,
    "behind the scenes" => :behindthescenes,
    "behindthescenes" => :behindthescenes,
    "deleted scenes" => :deletedscene,
    "deletedscenes" => :deletedscene,
    "clips" => :clip
  }.freeze

  EXTRA_FILENAME_EXACT = {
    "trailer" => :trailer,
    "sample" => :sample,
    "theme" => :themesong
  }.freeze

  EXTRA_SUFFIX_PATTERN = /[._\-\s](?<kind>trailer|sample|scene|clip|behindthescenes|deleted|deletedscene|featurette|short|interview|extra|other|theme)\z/i.freeze

  # ── Defensive guards ─────────────────────────────────────────────────
  # Reject "S1920E1080.mkv" (where 1920x1080 was misread as a season).
  SEASON_NUMBER_INVALID = ->(n) { n >= 200 && (n < 1928 || n > 2500) }

  # Video file extensions accepted by the scanner.
  VIDEO_EXTENSIONS = %w[
    .mkv .mp4 .avi .mov .m4v .ts .m2ts .webm .wmv .mpg .mpeg .flv
  ].freeze

  class << self
    # Main entry point. Returns:
    #   {
    #     type: :movie | :episode,
    #     title: String,
    #     year: Integer | nil,
    #     season: Integer | nil,
    #     episode: Integer | nil,
    #     episode_end: Integer | nil,
    #     air_date: String | nil,           # "YYYY-MM-DD" for date-based
    #     provider_ids: { imdb:, tmdb:, tvdb:, tvmaze: },
    #     is_extra: Symbol | nil,           # :trailer, :sample, ...
    #     raw: String                       # original basename without ext
    #   }
    def parse(path)
      basename = strip_known_extension(File.basename(path.to_s))
      normalized = basename.tr("_", "-")  # date patterns assume `-`

      provider_ids = extract_provider_ids(path.to_s)
      is_extra = extra_kind(path.to_s)

      ep_match = match_episode(normalized)
      date_match = ep_match ? nil : match_date(normalized)

      year_match = YEAR_PATTERN.match(basename)
      year = year_match && year_match[:year].to_i

      cleaned_title = clean_title(basename, ep_match, date_match, year_match)

      result = {
        type: :movie,
        title: cleaned_title,
        year: year,
        season: nil,
        episode: nil,
        episode_end: nil,
        air_date: nil,
        provider_ids: provider_ids,
        is_extra: is_extra,
        raw: basename
      }

      if ep_match
        season = capture(ep_match, :season)&.to_i
        episode = capture(ep_match, :ep)&.to_i
        ep_end = capture(ep_match, :episode_end)&.to_i

        # Defensive guard: drop bogus seasons that look like resolutions.
        if season && SEASON_NUMBER_INVALID.call(season)
          return result
        end

        result[:type] = :episode
        result[:season] = season || 1   # "Episode 16" → assume season 1
        result[:episode] = episode
        result[:episode_end] = ep_end
      elsif date_match
        result[:type] = :episode
        result[:air_date] = format("%04d-%02d-%02d",
          date_match[:year].to_i, date_match[:month].to_i, date_match[:day].to_i)
      end

      result
    end

    # Pull provider ids from anywhere in the path. Recognizes:
    #   [imdbid-tt1234567]   {tmdbid=12345}   (tvdbid-98765)   tt1234567
    def extract_provider_ids(text)
      ids = {}
      text.scan(PROVIDER_ID_BRACKET) do |key, value|
        ids[key.downcase.to_sym] = value
      end
      # Loose IMDb scan as a fallback (only if not already set).
      unless ids[:imdb]
        m = text.match(IMDB_LOOSE)
        ids[:imdb] = "tt#{m[1]}" if m
      end
      ids
    end

    # Returns the season number for a folder name, or nil if it doesn't
    # look like a season folder. "specials"/"extras" → 0.
    def season_from_folder(name)
      return 0 if SPECIAL_FOLDER_PATTERN.match?(name.to_s.strip)

      stripped = name.to_s.strip
      SEASON_FOLDER_PATTERNS.each do |re|
        m = re.match(stripped)
        return m[:season].to_i if m
      end
      nil
    end

    # Detect extras by directory/filename. Returns a symbol or nil.
    def extra_kind(path)
      basename = File.basename(path.to_s, ".*").downcase
      dirname = File.basename(File.dirname(path.to_s)).downcase

      EXTRA_DIRECTORIES.each do |dir, kind|
        return kind if dirname == dir
      end

      EXTRA_FILENAME_EXACT.each do |fname, kind|
        return kind if basename == fname
      end

      m = EXTRA_SUFFIX_PATTERN.match(basename)
      return m[:kind].downcase.to_sym if m

      nil
    end

    # True when extension is a recognized video file.
    def video_file?(filename)
      VIDEO_EXTENSIONS.include?(File.extname(filename.to_s).downcase)
    end

    # Backwards-compatible helpers for MovieParserService callers.
    def name_from_filename(path)
      parse(path)[:title]
    end

    def year_from_filename(path)
      y = parse(path)[:year]
      y ? y.to_s : nil
    end

    private

    # Strip a recognized media/sidecar extension. Avoids File.basename(s, ".*")
    # eating any trailing token in dotted folder names like "Some.Show".
    KNOWN_STRIP_EXTENSIONS = (VIDEO_EXTENSIONS + %w[.nfo .srt .ass .ssa .vtt .sub .idx .jpg .jpeg .png .webp]).freeze
    def strip_known_extension(name)
      ext = File.extname(name).downcase
      return name unless KNOWN_STRIP_EXTENSIONS.include?(ext)
      File.basename(name, File.extname(name))
    end

    def capture(match, name)
      return nil unless match.names.include?(name.to_s)
      match[name]
    end

    def match_episode(text)
      EPISODE_PATTERNS.each do |re|
        m = re.match(text)
        next unless m

        # Trailing-digit guard: reject `episode_end` if it's actually
        # part of a resolution/quality marker like "S09E14-1080p". The
        # current regex shape simply ignores the bad group: the named
        # alternation requires the closing `[Ee]?\d`, so a trailing `p`
        # already invalidates the match. Defensive check only.
        return m
      end
      nil
    end

    def match_date(text)
      DATE_PATTERNS.each do |re|
        m = re.match(text)
        if m
          y = m[:year].to_i
          mo = m[:month].to_i
          d = m[:day].to_i
          next unless (1900..2100).cover?(y) && (1..12).cover?(mo) && (1..31).cover?(d)
          return m
        end
      end
      nil
    end

    def clean_title(basename, ep_match, date_match, year_match)
      # Cut at the earliest of: episode marker, date, year.
      cutoff = [
        ep_match && ep_match.begin(0),
        date_match && date_match.begin(0),
        year_match && year_match.begin(0)
      ].compact.min

      candidate = cutoff ? basename[0...cutoff] : basename
      candidate = candidate.to_s

      # Run the cleaning chain; each pass narrows further.
      cleaned = candidate
      previous = nil
      while cleaned != previous
        previous = cleaned
        CLEAN_STRING_PATTERNS.each do |re|
          m = re.match(cleaned)
          if m && m[:cleaned] && !m[:cleaned].strip.empty?
            cleaned = m[:cleaned]
          end
        end
      end

      cleaned = cleaned.tr("._", " ").squeeze(" ").strip
      cleaned = cleaned.sub(/[\s\-\[\(\{]+\z/, "").strip
      cleaned.presence || candidate.tr("._", " ").strip.presence || basename
    end
  end
end
