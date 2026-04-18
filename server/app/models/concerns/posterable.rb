# Shared behavior for records that expose a `poster_url` (an external URL
# from TVMaze/IMDb) and want to cache the image as an ActiveStorage
# attachment so the client can load it from the Rails server instead of
# hitting the upstream CDN on every render.
module Posterable
  extend ActiveSupport::Concern
  require "net/http"
  require "uri"
  require "open-uri"

  POSTER_FETCH_TIMEOUT = 15 # seconds
  MAX_POSTER_BYTES = 15 * 1024 * 1024 # 15 MB ceiling — posters are ~500 KB

  # Bounding box for the client-facing variant. 600×900 covers every card
  # slot in the UI (TV ~200 px, desktop ~300 px) at 2× DPI and bounds each
  # poster to ~50–150 KB regardless of the source resolution (some IMDb
  # originals are 8K × 12K and 10 MB).
  POSTER_VARIANT = { resize_to_limit: [ 600, 900 ], saver: { quality: 82 } }.freeze

  included do
    has_one_attached :poster
  end

  def poster_variant
    return nil unless poster.attached?
    poster.variant(POSTER_VARIANT)
  end

  # Download the external poster_url and attach it as an ActiveStorage blob.
  # Returns true on success, false otherwise. Safe to call repeatedly —
  # ActiveStorage replaces any prior attachment on the record.
  def download_poster!
    return false if poster_url.blank?

    begin
      uri = URI.parse(poster_url)
      return false unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                 open_timeout: 5, read_timeout: POSTER_FETCH_TIMEOUT) do |http|
        http.get(uri.request_uri, "User-Agent" => "Caramba/1.0")
      end

      return false unless response.is_a?(Net::HTTPSuccess)
      return false if response.body.bytesize > MAX_POSTER_BYTES

      filename = File.basename(uri.path).presence || "poster.jpg"
      content_type = response["content-type"]&.split(";")&.first&.strip.presence ||
                     "image/jpeg"

      poster.attach(
        io: StringIO.new(response.body),
        filename: filename,
        content_type: content_type
      )
      true
    rescue => e
      Rails.logger.warn("Posterable: download failed for #{self.class}##{id} — #{e.message}")
      false
    end
  end
end
