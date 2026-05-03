# Reads Kodi-style .nfo XML sidecars next to media files.
#
# Ported from Jellyfin MediaBrowser.XbmcMetadata/Parsers/BaseNfoParser.cs.
# Recognizes the same tag set, including the IMDb / TMDb / TVDb provider
# IDs and the <uniqueid type="imdb"> form. Handles the Kodi quirk where
# Kodi appends a stray URL after the closing tag — we truncate at the
# closing tag before parsing.
#
# Returns a hash with the same keys TvmazeService#apply_show_data and
# ImdbApiService#apply_movie_data already write — drop-in seed.
#
# Public API (all class methods):
#   read_show(media_path)    — looks for tvshow.nfo in the directory
#   read_movie(file_path)    — looks for movie.nfo or <basename>.nfo next to file
#   read_episode(file_path)  — looks for <basename>.nfo next to file

require "rexml/document"

class NfoParserService
  ROOT_TAGS = {
    show: %w[tvshow],
    movie: %w[movie],
    episode: %w[episodedetails episode]
  }.freeze

  class << self
    def read_show(media_path)
      return nil if media_path.blank? || !Dir.exist?(media_path.to_s)
      nfo = File.join(media_path.to_s, "tvshow.nfo")
      return nil unless File.file?(nfo)
      parse_file(nfo, :show)
    end

    def read_movie(file_path)
      return nil if file_path.blank?
      nfo = nfo_for(file_path, "movie.nfo")
      return nil unless nfo
      parse_file(nfo, :movie)
    end

    def read_episode(file_path)
      return nil if file_path.blank?
      base = File.basename(file_path, File.extname(file_path))
      candidate = File.join(File.dirname(file_path), "#{base}.nfo")
      return nil unless File.file?(candidate)
      parse_file(candidate, :episode)
    end

    private

    # Look for `<basename>.nfo` first, then a generic `<sidecar_name>` in
    # the same directory.
    def nfo_for(file_path, sidecar_name)
      base = File.basename(file_path, File.extname(file_path))
      dir = File.dirname(file_path)

      sibling = File.join(dir, "#{base}.nfo")
      return sibling if File.file?(sibling)

      generic = File.join(dir, sidecar_name)
      return generic if File.file?(generic)

      nil
    end

    def parse_file(path, kind)
      raw = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace)
      truncated = truncate_to_root(raw, ROOT_TAGS[kind])
      doc = REXML::Document.new(truncated)
      root = doc.root
      return nil unless root
      build_attrs(root, kind)
    rescue => e
      Rails.logger.warn("[NfoParser] failed to parse #{path}: #{e.message}")
      nil
    end

    # Kodi sometimes writes `</movie>https://www.themoviedb.org/movie/123`
    # — extra junk after the closing tag breaks REXML. Cut at the first
    # closing tag we recognize.
    def truncate_to_root(raw, root_tags)
      root_tags.each do |tag|
        idx = raw.index("</#{tag}>")
        if idx
          return raw[0..(idx + tag.length + 2)]
        end
      end
      raw
    end

    def build_attrs(root, kind)
      attrs = {}

      title = text(root, "title") || text(root, "originaltitle")
      attrs[:title] = title if title.present?

      plot = text(root, "plot") || text(root, "outline")
      attrs[:description] = strip_html(plot) if plot.present?

      year = text(root, "year")
      attrs[:year] = year if year.present?

      premiered = text(root, "premiered") || text(root, "aired") || text(root, "releasedate")
      attrs[:premiered] = premiered if premiered.present?
      attrs[:air_date] = premiered if premiered.present? && kind == :episode

      runtime = text(root, "runtime")
      attrs[:runtime] = runtime.to_i if runtime.present? && runtime.to_i > 0

      rating = text(root, "rating") || text(root, "ratings/rating[@default='true']/value")
      attrs[:rating] = rating.to_f if rating.present?

      genres = root.get_elements("genre").map { |g| g.text&.strip }.compact_blank
      attrs[:genres] = genres.join(", ") if genres.any?

      directors = root.get_elements("director").map { |d| d.text&.strip }.compact_blank
      attrs[:director] = directors.join(", ") if directors.any?

      season = text(root, "season")
      attrs[:season_number] = season.to_i if season.present? && kind == :episode

      episode = text(root, "episode")
      attrs[:episode_number] = episode.to_i if episode.present? && kind == :episode

      attrs[:provider_ids] = extract_provider_ids(root)

      # Promote canonical IDs to top-level attrs to match the existing
      # apply_*_data hashes elsewhere.
      attrs[:imdb_id] = attrs[:provider_ids][:imdb] if attrs[:provider_ids][:imdb]
      attrs[:tvmaze_id] = attrs[:provider_ids][:tvmaze]&.to_i if attrs[:provider_ids][:tvmaze]

      attrs
    end

    def extract_provider_ids(root)
      ids = {}
      ids[:imdb] = text(root, "imdbid") || text(root, "imdb_id")
      ids[:tmdb] = text(root, "tmdbid") || text(root, "tmdb_id")
      ids[:tvdb] = text(root, "tvdbid") || text(root, "tvdb_id")
      ids[:tvmaze] = text(root, "tvmazeid") || text(root, "tvmaze_id")

      # Modern Kodi uses <uniqueid type="imdb">tt1234567</uniqueid>
      root.get_elements("uniqueid").each do |el|
        type = el.attribute("type")&.value&.downcase
        next unless type
        value = el.text&.strip
        next if value.blank?
        case type
        when "imdb" then ids[:imdb] ||= value
        when "tmdb" then ids[:tmdb] ||= value
        when "tvdb" then ids[:tvdb] ||= value
        when "tvmaze" then ids[:tvmaze] ||= value
        end
      end

      ids.compact
    end

    def text(root, xpath)
      el = root.elements[xpath]
      el&.text&.strip
    end

    def strip_html(html)
      return nil if html.blank?
      text = html.gsub(/<[^>]+>/, "")
      text = text.gsub("&amp;", "&")
        .gsub("&lt;", "<")
        .gsub("&gt;", ">")
        .gsub("&quot;", '"')
        .gsub("&#39;", "'")
        .gsub("&nbsp;", " ")
      text.strip.presence
    end
  end
end
