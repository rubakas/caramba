# Fetches movie metadata from the IMDb API (imdbapi.dev).
#
# No API key required. No known rate limit. Returns high-resolution
# poster images, IMDb ratings, metacritic scores, plot, directors,
# genres, and runtime.
#
# API docs: https://imdbapi.dev
#
# Usage:
#   MovieMetadataFetcher.fetch!(movie)
#
class MovieMetadataFetcher
  BASE_URL = 'https://api.imdbapi.dev'.freeze

  class << self
    def fetch!(movie)
      # Step 1: Search by title to find the IMDb ID
      result = search(movie.title)
      return false unless result

      # Step 2: Get full details by IMDb ID
      data = get_title(result['id'])
      return false unless data

      apply_metadata!(movie, data)
      true
    rescue StandardError => e
      Rails.logger.warn("MovieMetadataFetcher: failed for '#{movie.title}' — #{e.message}")
      false
    end

    def search(title)
      uri = URI("#{BASE_URL}/search/titles")
      uri.query = URI.encode_www_form(query: title, limit: 1)

      response = http_get(uri)
      return nil unless response.is_a?(Net::HTTPSuccess)

      data = JSON.parse(response.body)
      titles = data['titles']
      return nil if titles.blank?

      # Return first movie result (prefer type "movie")
      titles.find { |t| t['type'] == 'movie' } || titles.first
    rescue StandardError => e
      Rails.logger.warn("MovieMetadataFetcher: search failed for '#{title}' — #{e.message}")
      nil
    end

    def get_title(imdb_id)
      uri = URI("#{BASE_URL}/titles/#{imdb_id}")

      response = http_get(uri)
      return nil unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue StandardError => e
      Rails.logger.warn("MovieMetadataFetcher: get_title failed for '#{imdb_id}' — #{e.message}")
      nil
    end

    private

    def apply_metadata!(movie, data)
      attrs = {}

      # Poster — imdbapi.dev returns high-res Amazon images
      poster_url = data.dig('primaryImage', 'url')
      attrs[:poster_url] = poster_url if poster_url.present?

      attrs[:description] = data['plot'] if data['plot'].present?
      attrs[:year]        = data['startYear'].to_s if data['startYear'].present?
      attrs[:imdb_id]     = data['id'] if data['id'].present?

      # Genres — array of strings
      attrs[:genres] = data['genres'].join(', ') if data['genres'].is_a?(Array) && data['genres'].any?

      # Rating
      aggregate = data.dig('rating', 'aggregateRating')
      attrs[:rating] = aggregate.to_f if aggregate.present?

      # Directors — array of name objects
      if data['directors'].is_a?(Array) && data['directors'].any?
        attrs[:director] = data['directors'].map { |d| d['displayName'] }.compact.join(', ')
      end

      # Runtime — returned in seconds
      if data['runtimeSeconds'].present? && data['runtimeSeconds'].to_i > 0
        attrs[:runtime] = (data['runtimeSeconds'].to_i / 60.0).round
      end

      movie.update!(attrs) if attrs.any?

      Rails.logger.info("MovieMetadataFetcher: updated '#{movie.title}' (IMDb: #{data['id']})")
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
