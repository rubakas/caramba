require 'fileutils'
require 'digest'
require 'open3'

module Jellyfin
  module Trickplay
    # Generates trickplay scrubber preview tiles. The model upstream uses:
    #
    #   - Capture one frame every N seconds with `-vf fps=1/N`
    #   - Scale each frame to the trickplay width
    #   - Pack frames into a tile sprite (10x10 grid per JPEG)
    #   - Write a manifest the client can use to map (timestamp → tile, offset)
    #
    # The simplified port here generates per-second JPEG frames at the chosen
    # width and emits a manifest. Sprite packing is left as an optimisation —
    # individual JPEGs are correct, just slower to fetch in bulk.
    class Generator
      # Pixel widths the upstream Jellyfin generates by default.
      DEFAULT_WIDTHS = [320, 480].freeze
      DEFAULT_INTERVAL = 10 # seconds

      def initialize(ffmpeg_path:, cache_root:)
        @ffmpeg = ffmpeg_path
        @cache_root = cache_root
      end

      # Generates trickplay tiles for one (path, width). Returns a manifest:
      #   { width:, interval:, total: N, tile_dir: ".../trickplay/<sha>/<width>" }
      # The directory contains 0.jpg, 1.jpg, ... N-1.jpg.
      def generate(source_path:, width: 320, interval: DEFAULT_INTERVAL)
        return nil unless File.exist?(source_path)
        dir = dir_for(source_path, width)
        manifest_path = File.join(dir, 'manifest.json')

        if File.exist?(manifest_path) && fresh?(manifest_path, source_path)
          return load_manifest(manifest_path)
        end

        FileUtils.rm_rf(dir)
        FileUtils.mkdir_p(dir)
        run_ffmpeg(source_path, dir, width, interval)
        count = Dir.glob(File.join(dir, '*.jpg')).size
        manifest = { 'width' => width, 'interval' => interval, 'total' => count,
                     'tile_dir' => dir, 'mtime' => File.mtime(source_path).to_i }
        File.write(manifest_path, JSON.dump(manifest))
        manifest
      end

      def tile_path(source_path:, width:, index:)
        File.join(dir_for(source_path, width), "#{index}.jpg")
      end

      # An HLS-style m3u8 listing of trickplay tiles. Some players consume
      # this directly; others use the manifest JSON instead.
      def tiles_playlist(source_path:, width:, total:, interval:)
        lines = ['#EXTM3U', '#EXT-X-VERSION:6',
                 "#EXT-X-TARGETDURATION:#{interval}",
                 '#EXT-X-PLAYLIST-TYPE:VOD',
                 '#EXT-X-IMAGES-ONLY']
        total.times do |i|
          lines << "#EXTINF:#{interval}.0,"
          lines << "#{i}.jpg"
        end
        lines << '#EXT-X-ENDLIST'
        lines.join("\n")
      end

      private

      def dir_for(source_path, width)
        digest = Digest::SHA1.hexdigest(File.expand_path(source_path))
        File.join(@cache_root, 'trickplay', digest, width.to_s)
      end

      def fresh?(manifest_path, source_path)
        require 'json'
        data = JSON.parse(File.read(manifest_path))
        data['mtime'].to_i == File.mtime(source_path).to_i
      rescue StandardError
        false
      end

      def load_manifest(manifest_path)
        require 'json'
        JSON.parse(File.read(manifest_path))
      end

      def run_ffmpeg(source_path, dir, width, interval)
        cmd = [@ffmpeg, '-y', '-hide_banner', '-loglevel', 'error',
               '-skip_frame', 'nokey',
               '-i', source_path,
               '-vsync', 'vfr',
               '-vf', "fps=1/#{interval},scale=#{width}:-2",
               '-q:v', '5',
               File.join(dir, '%d.jpg')]
        _out, _err, _status = Open3.capture3(*cmd)
      end
    end
  end
end
