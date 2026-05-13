require 'json'
require 'open3'
require 'digest'
require 'jellyfin/probing/probe_result_normalizer'

module Jellyfin
  module MediaEncoder
    # ffprobe wrapper. Shells `ffprobe -show_streams -show_format -show_chapters -of json`
    # and feeds the result to ProbeResultNormalizer.
    #
    # Mirrors MediaBrowser.MediaEncoding/Encoder/MediaEncoder.cs#GetMediaInfo* at the
    # level jellyfin-rails needs.
    class Probe
      class ProbeFailed < StandardError; end

      def self.from_path(path, cache: default_cache)
        new(path).fetch(cache: cache)
      end

      def self.default_cache
        if defined?(::Rails) && ::Rails.respond_to?(:cache) && ::Rails.cache
          ::Rails.cache
        else
          NullCache.instance
        end
      end

      def initialize(path)
        @path = path
      end

      def fetch(cache: self.class.default_cache)
        cache.fetch(cache_key) { call }
      end

      def call
        out, err, status = Open3.capture3(
          Jellyfin::Rails.configuration.ffprobe_path,
          '-hide_banner',
          '-loglevel', 'warning',
          '-print_format', 'json',
          '-show_format',
          '-show_streams',
          '-show_chapters',
          @path
        )
        raise ProbeFailed, "ffprobe failed: #{err.strip}" unless status.success?
        Jellyfin::Probing::ProbeResultNormalizer.call(JSON.parse(out), path: @path)
      end

      private

      def cache_key
        stat = File.stat(@path)
        ['jellyfin', 'probe', @path, stat.mtime.to_i, stat.size]
      rescue Errno::ENOENT
        ['jellyfin', 'probe', @path, 0, 0]
      end

      class NullCache
        require 'singleton'
        include Singleton
        def fetch(_key) = yield
      end
    end
  end
end
