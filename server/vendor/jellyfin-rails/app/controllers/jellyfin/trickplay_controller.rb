require 'jellyfin/transcoding/token'
require 'jellyfin/trickplay/generator'

module Jellyfin
  # GET /trickplay/:token/:width/index.m3u8 — playlist of tile JPEGs
  # GET /trickplay/:token/:width/:index.jpg — single tile
  class TrickplayController < ApplicationController
    DEFAULT_INTERVAL = 10

    def index
      manifest = ensure_generated(width)
      return render(json: { error: 'generation failed' }, status: 500) unless manifest

      playlist = generator.tiles_playlist(
        source_path: path,
        width: width,
        total: manifest['total'],
        interval: manifest['interval'] || DEFAULT_INTERVAL
      )
      render plain: playlist, content_type: 'application/vnd.apple.mpegurl'
    end

    def tile
      ensure_generated(width)
      file = generator.tile_path(source_path: path, width: width, index: params[:index].to_i)
      return head(:not_found) unless File.exist?(file)
      send_file file, type: 'image/jpeg', disposition: 'inline'
    end

    private

    def path
      @path ||= begin
        payload = Jellyfin::Transcoding::Token.decode(params[:token])
        payload[:path].to_s
      end
    end

    def width
      @width ||= params[:width].to_i.then { |w| w.zero? ? 320 : w }
    end

    def generator
      @generator ||= Jellyfin::Trickplay::Generator.new(
        ffmpeg_path: Jellyfin::Rails.configuration.ffmpeg_path,
        cache_root: Jellyfin::Rails.configuration.resolved_transcode_dir.to_s
      )
    end

    def ensure_generated(width)
      generator.generate(source_path: path, width: width, interval: DEFAULT_INTERVAL)
    end
  end
end
