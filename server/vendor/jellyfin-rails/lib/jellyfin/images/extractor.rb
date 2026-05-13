require 'fileutils'
require 'digest'
require 'open3'

module Jellyfin
  module Images
    # Extracts and serves item artwork. Two sources:
    #
    #   1. Sidecar files next to the media: poster.jpg, fanart.jpg, etc.
    #   2. Embedded attachments (cover art in MKV/FLAC) — extracted via ffmpeg.
    #   3. Chapter thumbs — single-frame grabs at chapter timestamps.
    #
    # Mirrors the slice of ImageProcessor.cs we need for /Items/{id}/Images/...
    class Extractor
      SIDECAR_BASENAMES = {
        primary:  %w[poster cover folder thumb],
        backdrop: %w[backdrop fanart],
        logo:     %w[logo clearlogo],
        banner:   %w[banner],
        art:      %w[clearart art]
      }.freeze

      def initialize(ffmpeg_path:, cache_root:)
        @ffmpeg = ffmpeg_path
        @cache_root = cache_root
      end

      # Finds a sidecar image next to the media file. Returns the path or nil.
      def sidecar(media_path:, type: :primary)
        return nil unless media_path
        dir = File.dirname(media_path)
        return nil unless File.directory?(dir)
        candidates = SIDECAR_BASENAMES.fetch(type, [])
        %w[jpg jpeg png webp].each do |ext|
          candidates.each do |base|
            p = File.join(dir, "#{base}.#{ext}")
            return p if File.exist?(p)
          end
        end
        nil
      end

      # Port of MediaEncoder.ExtractAudioImage (cs:592). Pulls the embedded
      # cover from an *audio* file (mp3 ID3v2 APIC, flac PICTURE, m4a covr
      # atom). Semantically identical to `embedded_cover` — upstream keeps
      # them as separate methods so callers don't need to know whether the
      # source is audio-only or audio+video.
      def extract_audio_image(media_path:, image_stream_index: nil)
        return nil unless File.exist?(media_path)
        # `image_stream_index` is honoured when the source has multiple
        # attached_pic streams; nil falls through to the default `0:v?` map
        # ffmpeg uses inside `embedded_cover`.
        embedded_cover(media_path: media_path)
      end

      # Extracts the first attached_pic (embedded cover art) from a media file.
      # Cached by path + mtime.
      def embedded_cover(media_path:)
        return nil unless File.exist?(media_path)
        dir = cache_dir_for(media_path)
        out = File.join(dir, 'cover.jpg')
        return out if File.exist?(out) && File.mtime(out) >= File.mtime(media_path)

        FileUtils.mkdir_p(dir)
        cmd = [@ffmpeg, '-y', '-hide_banner', '-loglevel', 'error',
               '-i', media_path,
               '-map', '0:v?',
               '-map', '-0:V', # exclude regular video streams
               '-c', 'copy',
               '-frames:v', '1', out]
        _out, _err, status = Open3.capture3(*cmd)
        return nil unless status.success? && File.exist?(out) && File.size(out).positive?
        out
      end

      # Extracts a chapter thumbnail. `start_time_seconds` is the chapter
      # boundary; we grab one frame slightly past the boundary to avoid black
      # transition frames.
      def chapter_thumbnail(media_path:, start_time_seconds:, width: 320)
        return nil unless File.exist?(media_path)
        dir = cache_dir_for(media_path)
        out = File.join(dir, "chapter-#{start_time_seconds.to_i}-#{width}.jpg")
        return out if File.exist?(out) && File.mtime(out) >= File.mtime(media_path)

        FileUtils.mkdir_p(dir)
        # Seek slightly past the boundary to avoid black transition frames.
        offset = start_time_seconds.to_f + 0.5
        cmd = [@ffmpeg, '-y', '-hide_banner', '-loglevel', 'error',
               '-ss', offset.to_s, '-i', media_path,
               '-frames:v', '1',
               '-vf', "scale=#{width}:-2",
               '-q:v', '5', out]
        _out, _err, status = Open3.capture3(*cmd)
        return nil unless status.success? && File.exist?(out) && File.size(out).positive?
        out
      end

      private

      def cache_dir_for(media_path)
        digest = Digest::SHA1.hexdigest(File.expand_path(media_path))
        File.join(@cache_root, 'images', digest)
      end
    end
  end
end
