# Fetches TV show metadata from TVMaze API.
# No API key needed. Rate limit: 20 calls/10s.
# Ported from desktop/electron/services/metadata-fetcher.js + ipc/discover.js
#
# Public API (all class methods):
#   search_shows(query)              — discover search, returns array of mapped show hashes
#   show_details(tvmaze_id)          — discover detail modal, returns { show:, episodes:, seasons: }
#   fetch_for_show(show)             — updates Show + Episode records from TVMaze data (by name)
#   fetch_by_tvmaze_id(show, id)     — updates Show + Episode records from TVMaze data (by id)

require "net/http"
require "json"
require "uri"

class TvmazeService
  BASE_URL = "https://api.tvmaze.com"
  TIMEOUT  = 15 # seconds

  class << self
    # Search shows — returns array of hashes matching the mapShow() shape from discover.js
    def search_shows(query)
      url = "#{BASE_URL}/search/shows?q=#{URI.encode_www_form_component(query)}"
      data = get_json(url)
      return [] unless data.is_a?(Array)

      data.filter_map do |result|
        show = result["show"]
        next unless show
        map_show(show).merge("score" => result["score"])
      end
    end

    # Full show details with episodes, grouped by season — for discover detail modal
    def show_details(tvmaze_id)
      url = "#{BASE_URL}/shows/#{tvmaze_id}?embed=episodes"
      data = get_json(url)
      return nil unless data.is_a?(Hash) && data["id"]

      show = map_show(data)

      episodes = (data.dig("_embedded", "episodes") || []).map do |ep|
        {
          "tvmaze_id" => ep["id"],
          "season" => ep["season"],
          "number" => ep["number"],
          "name" => ep["name"],
          "airdate" => ep["airdate"].presence,
          "runtime" => ep["runtime"],
          "summary" => strip_html(ep["summary"])
        }
      end

      seasons = episodes.group_by { |ep| ep["season"] }

      { "show" => show, "episodes" => episodes, "seasons" => seasons }
    end

    # Fetch metadata for a Show record and update it + its episodes in DB.
    # Looks up by name via singlesearch. Returns true on success, false otherwise.
    def fetch_for_show(show)
      url = "#{BASE_URL}/singlesearch/shows?q=#{URI.encode_www_form_component(show.name)}&embed=episodes"
      data = get_json(url)
      return false unless data.is_a?(Hash) && data["id"]
      apply_show_data(show, data)
    rescue => e
      Rails.logger.warn("TvmazeService: fetch_for_show failed for '#{show.name}' — #{e.message}")
      false
    end

    # Same as fetch_for_show but by explicit tvmaze_id — used by the admin
    # match-confirmation flow where the user has already picked a candidate.
    def fetch_by_tvmaze_id(show, tvmaze_id)
      url = "#{BASE_URL}/shows/#{tvmaze_id}?embed=episodes"
      data = get_json(url)
      return false unless data.is_a?(Hash) && data["id"]
      apply_show_data(show, data)
    rescue => e
      Rails.logger.warn("TvmazeService: fetch_by_tvmaze_id failed for tvmaze_id=#{tvmaze_id} — #{e.message}")
      false
    end

    private

    def apply_show_data(show, data)
      poster_url = data.dig("image", "original") || data.dig("image", "medium")
      summary = strip_html(data["summary"])

      poster_changed = show.poster_url != poster_url

      show.update!(
        tvmaze_id: data["id"],
        poster_url: poster_url,
        description: summary,
        genres: data["genres"].is_a?(Array) ? data["genres"].join(", ") : nil,
        rating: data.dig("rating", "average"),
        premiered: data["premiered"],
        status: data["status"],
        imdb_id: data.dig("externals", "imdb")
      )

      show.download_poster! if poster_changed && poster_url.present?

      api_episodes = data.dig("_embedded", "episodes") || []
      if api_episodes.any?
        api_lookup = {}
        api_episodes.each do |ep|
          next if ep["season"].nil? || ep["number"].nil?
          code = format("S%02dE%02d", ep["season"], ep["number"])
          api_lookup[code] = ep
        end

        local_episodes = show.episodes.to_a
        matched = 0

        local_episodes.each do |episode|
          api_ep = api_lookup[episode.code]
          next unless api_ep

          attrs = {}
          ep_summary = strip_html(api_ep["summary"])
          attrs[:description] = ep_summary if ep_summary.present?
          attrs[:air_date] = api_ep["airdate"] if api_ep["airdate"].present?
          attrs[:runtime] = api_ep["runtime"] if api_ep["runtime"].present?
          attrs[:tvmaze_id] = api_ep["id"] if api_ep["id"].present?

          if attrs.any?
            episode.update!(attrs)
            matched += 1
          end
        end

        Rails.logger.info("TvmazeService: matched #{matched}/#{local_episodes.size} episodes with TVMaze data")
      end

      Rails.logger.info("TvmazeService: updated show '#{show.name}' (TVMaze ID: #{data["id"]})")
      true
    end


    # Map a TVMaze show object to the shape expected by the React UI (matches discover.js mapShow)
    def map_show(show)
      {
        "_type" => "show",
        "tvmaze_id" => show["id"],
        "name" => show["name"],
        "poster_url" => show.dig("image", "original") || show.dig("image", "medium"),
        "description" => strip_html(show["summary"]),
        "genres" => (show["genres"] || []).join(", "),
        "rating" => show.dig("rating", "average"),
        "premiered" => show["premiered"],
        "status" => show["status"],
        "network" => show.dig("network", "name") || show.dig("webChannel", "name"),
        "imdb_id" => show.dig("externals", "imdb"),
        "type" => show["type"],
        "language" => show["language"],
        "runtime" => show["runtime"] || show["averageRuntime"],
        "schedule" => show["schedule"],
        "officialSite" => show["officialSite"]
      }
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
        Rails.logger.warn("TvmazeService: rate limited, retrying after #{retry_after}s")
        sleep(retry_after)
        return get_json(url, retried: true)
      end

      return nil unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue => e
      Sentry.capture_exception(e, tags: { subsystem: "tvmaze" }) if defined?(Sentry) && Sentry.initialized?
      Rails.logger.warn("TvmazeService: HTTP request failed for #{url} — #{e.message}")
      nil
    end
  end
end
