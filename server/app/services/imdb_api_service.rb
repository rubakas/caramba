# Fetches movie metadata from imdbapi.dev.
# No API key required, no known rate limit.
# Ported from desktop/electron/services/movie-metadata.js + ipc/discover.js
#
# Public API (all class methods):
#   search_titles(query)       — discover search, returns array of mapped movie hashes
#   title_details(imdb_id)     — discover detail, returns movie detail hash
#   fetch_for_movie(movie)     — updates Movie record from IMDB data, returns true/false

require "net/http"
require "json"
require "uri"

class ImdbApiService
  BASE_URL = "https://api.imdbapi.dev"
  TIMEOUT  = 15 # seconds

  class << self
    # Search titles — returns array of hashes matching the mapMovie() shape from discover.js
    # Only returns movies (filters by type)
    def search_titles(query)
      url = "#{BASE_URL}/search/titles?query=#{URI.encode_www_form_component(query)}&limit=10"
      data = get_json(url)
      return [] unless data.is_a?(Hash) && data["titles"].is_a?(Array)

      data["titles"]
        .select { |t| t["type"] == "movie" }
        .map { |t| map_movie(t) }
    end

    # Full movie details — for discover detail modal
    # Returns hash matching the shape from discover.js movieDetails handler
    def title_details(imdb_id)
      url = "#{BASE_URL}/titles/#{imdb_id}"
      data = get_json(url)
      return nil unless data.is_a?(Hash) && data["id"]

      {
        "imdb_id" => data["id"],
        "description" => data["plot"],
        "genres" => data["genres"].is_a?(Array) ? data["genres"].join(", ") : nil,
        "director" => data["directors"].is_a?(Array) ? data["directors"].filter_map { |d| d["displayName"] }.join(", ") : nil,
        "runtime" => data["runtimeSeconds"] && data["runtimeSeconds"].to_i > 0 ? (data["runtimeSeconds"].to_i / 60.0).round : nil,
        "year" => data["startYear"] ? data["startYear"].to_s : nil,
        "rating" => data.dig("rating", "aggregateRating"),
        "poster_url" => data.dig("primaryImage", "url")
      }
    end

    # Fetch metadata for a Movie record and update it in DB.
    # Returns true on success, false otherwise.
    def fetch_for_movie(movie)
      result = search_title(movie.title)
      return false unless result

      data = get_title_details(result["id"])
      return false unless data

      attrs = {}
      attrs[:poster_url] = data.dig("primaryImage", "url") if data.dig("primaryImage", "url").present?
      attrs[:description] = data["plot"] if data["plot"].present?
      attrs[:year] = data["startYear"].to_s if data["startYear"].present?
      attrs[:imdb_id] = data["id"] if data["id"].present?
      attrs[:genres] = data["genres"].join(", ") if data["genres"].is_a?(Array) && data["genres"].any?
      attrs[:rating] = data.dig("rating", "aggregateRating")&.to_f if data.dig("rating", "aggregateRating")
      attrs[:director] = data["directors"].filter_map { |d| d["displayName"] }.join(", ") if data["directors"].is_a?(Array) && data["directors"].any?
      attrs[:runtime] = (data["runtimeSeconds"].to_i / 60.0).round if data["runtimeSeconds"] && data["runtimeSeconds"].to_i > 0

      movie.update!(attrs) if attrs.any?

      Rails.logger.info("ImdbApiService: updated '#{movie.title}' (IMDb: #{data["id"]})")
      true
    rescue => e
      Rails.logger.warn("ImdbApiService: fetch_for_movie failed for '#{movie.title}' — #{e.message}")
      false
    end

    private

    # Map an imdbapi title to the shape expected by React UI (matches discover.js mapMovie)
    def map_movie(title)
      {
        "_type" => "movie",
        "imdb_id" => title["id"],
        "name" => title["primaryTitle"] || title["originalTitle"] || "Unknown",
        "poster_url" => title.dig("primaryImage", "url"),
        "year" => title["startYear"] ? title["startYear"].to_s : nil,
        "rating" => title.dig("rating", "aggregateRating")
      }
    end

    # Internal: search for a single title (first movie result) — used by fetch_for_movie
    def search_title(title)
      url = "#{BASE_URL}/search/titles?query=#{URI.encode_www_form_component(title)}&limit=1"
      data = get_json(url)
      return nil unless data.is_a?(Hash) && data["titles"].is_a?(Array) && data["titles"].any?

      data["titles"].find { |t| t["type"] == "movie" } || data["titles"].first
    end

    # Internal: get full title details — used by fetch_for_movie
    def get_title_details(imdb_id)
      url = "#{BASE_URL}/titles/#{imdb_id}"
      data = get_json(url)
      return nil unless data.is_a?(Hash) && data["id"]
      data
    end

    def get_json(url, retried: false)
      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = TIMEOUT
      http.read_timeout = TIMEOUT

      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/json"

      response = http.request(request)

      # Handle rate limiting (429) with single retry
      if response.code == "429" && !retried
        retry_after = (response["retry-after"] || "10").to_i
        Rails.logger.warn("ImdbApiService: rate limited, retrying after #{retry_after}s")
        sleep(retry_after)
        return get_json(url, retried: true)
      end

      return nil unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue => e
      Rails.logger.warn("ImdbApiService: HTTP request failed for #{url} — #{e.message}")
      nil
    end
  end
end
