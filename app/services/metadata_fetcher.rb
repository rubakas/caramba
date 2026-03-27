# Fetches TV series metadata and episode details from the TVMaze API.
#
# TVMaze is free, requires no API key, and returns posters, descriptions,
# genres, ratings, and per-episode details in a single request.
#
# API docs: https://www.tvmaze.com/api
# Rate limit: 20 calls per 10 seconds per IP.
#
# Usage:
#   MetadataFetcher.fetch!(series)            # fetch metadata for a Series record
#   MetadataFetcher.search("Breaking Bad")    # search without saving
#
class MetadataFetcher
  BASE_URL = 'https://api.tvmaze.com'.freeze

  class << self
    # Fetch metadata for a Series record and update it + its episodes.
    # Returns true if metadata was found and applied, false otherwise.
    def fetch!(series)
      data = search(series.name)
      return false unless data

      apply_series_metadata!(series, data)
      apply_episode_metadata!(series, data['_embedded']&.dig('episodes') || [])
      true
    rescue StandardError => e
      Rails.logger.warn("MetadataFetcher: failed for '#{series.name}' — #{e.message}")
      false
    end

    # Search TVMaze for a show by name. Returns the raw JSON hash
    # with embedded episodes, or nil if not found.
    def search(query)
      uri = URI("#{BASE_URL}/singlesearch/shows")
      uri.query = URI.encode_www_form(q: query, embed: 'episodes')

      response = http_get(uri)
      return nil unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue StandardError => e
      Rails.logger.warn("MetadataFetcher: search failed for '#{query}' — #{e.message}")
      nil
    end

    private

    def apply_series_metadata!(series, data)
      poster_url = data.dig('image', 'original') || data.dig('image', 'medium')
      summary = strip_html(data['summary'])

      series.update!(
        tvmaze_id: data['id'],
        poster_url: poster_url,
        description: summary,
        genres: Array(data['genres']).join(', '),
        rating: data.dig('rating', 'average'),
        premiered: data['premiered'],
        status: data['status'],
        imdb_id: data.dig('externals', 'imdb')
      )

      Rails.logger.info("MetadataFetcher: updated series '#{series.name}' (TVMaze ID: #{data['id']})")
    end

    def apply_episode_metadata!(series, api_episodes)
      return if api_episodes.empty?

      # Build a lookup by SxxExx code from the API data
      api_lookup = {}
      api_episodes.each do |ep|
        season = ep['season']
        number = ep['number']
        next unless season && number

        code = format('S%02dE%02d', season, number)
        api_lookup[code] = ep
      end

      # Match against our locally-scanned episodes
      matched = 0
      series.episodes.find_each do |episode|
        api_ep = api_lookup[episode.code]
        next unless api_ep

        attrs = {}
        summary = strip_html(api_ep['summary'])
        attrs[:description] = summary if summary.present?
        attrs[:air_date]    = api_ep['airdate'] if api_ep['airdate'].present?
        attrs[:runtime]     = api_ep['runtime'] if api_ep['runtime']
        attrs[:tvmaze_id]   = api_ep['id'] if api_ep['id']

        if attrs.any?
          episode.update!(attrs)
          matched += 1
        end
      end

      Rails.logger.info("MetadataFetcher: matched #{matched}/#{series.episodes.count} episodes with TVMaze data")
    end

    def strip_html(html)
      return nil if html.blank?

      # Remove HTML tags and decode common entities
      text = html.gsub(/<[^>]+>/, '')
      text = text.gsub('&amp;', '&')
                 .gsub('&lt;', '<')
                 .gsub('&gt;', '>')
                 .gsub('&quot;', '"')
                 .gsub('&#39;', "'")
                 .gsub('&nbsp;', ' ')
      text.strip.presence
    end

    def http_get(uri)
      require 'net/http'
      require 'json'
      require 'uri'

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 15

      request = Net::HTTP::Get.new(uri)
      request['Accept'] = 'application/json'

      http.request(request)
    end
  end
end
