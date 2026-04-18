# Shared behavior for records that expose a `poster_url` (an external URL
# from TVMaze/IMDb) and want to cache the image as an ActiveStorage
# attachment so the client can load it from the Rails server instead of
# hitting the upstream CDN on every render.
module Posterable
  extend ActiveSupport::Concern
  require "net/http"
  require "uri"
  require "tempfile"
  require "image_processing/vips"

  POSTER_FETCH_TIMEOUT = 15 # seconds
  MAX_SOURCE_BYTES = 25 * 1024 * 1024 # 25 MB cap on what we'll download — some IMDb originals are 10 MB+

  # Target size for the stored blob. 600×900 covers every card slot in the UI
  # (TV ~200 px, desktop ~300 px) at 2× DPI. We resize at download time rather
  # than storing the 8K × 12K source and generating a variant on read, so the
  # blob on disk is already the small version and the first request doesn't
  # have to pipe a 10 MB file through libvips.
  POSTER_MAX_WIDTH = 600
  POSTER_MAX_HEIGHT = 900
  POSTER_QUALITY = 82

  included do
    has_one_attached :poster
  end

  # Download the external poster_url, resize it to POSTER_MAX_WIDTH ×
  # POSTER_MAX_HEIGHT via libvips, and attach the resulting JPEG as an
  # ActiveStorage blob. Returns true on success, false otherwise. Safe to
  # call repeatedly — ActiveStorage replaces any prior attachment.
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
      return false if response.body.bytesize > MAX_SOURCE_BYTES

      resized = resize_poster(response.body)
      return false unless resized

      poster.attach(
        io: resized,
        filename: "poster.jpg",
        content_type: "image/jpeg"
      )
      true
    rescue => e
      Rails.logger.warn("Posterable: download failed for #{self.class}##{id} — #{e.message}")
      false
    ensure
      resized&.close!
    end
  end

  private

  # Pipe the downloaded bytes through libvips. Returns a Tempfile of the
  # resized JPEG, or nil on failure. Caller is responsible for closing it.
  def resize_poster(bytes)
    source = Tempfile.new([ "poster_src", ".bin" ], binmode: true)
    source.write(bytes)
    source.rewind

    ImageProcessing::Vips
      .source(source)
      .resize_to_limit(POSTER_MAX_WIDTH, POSTER_MAX_HEIGHT)
      .convert("jpg")
      .saver(quality: POSTER_QUALITY, strip: true)
      .call
  rescue Vips::Error, StandardError => e
    Rails.logger.warn("Posterable: resize failed for #{self.class}##{id} — #{e.message}")
    nil
  ensure
    source&.close!
  end
end
