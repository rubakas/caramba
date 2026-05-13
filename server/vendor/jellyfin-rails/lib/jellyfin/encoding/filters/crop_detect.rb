require 'open3'

module Jellyfin
  module Encoding
    module Filters
      # Auto-detect letterbox / pillarbox black bars and crop them off. Runs a
      # short ffmpeg measurement pass through the `cropdetect` filter, parses
      # the recommended crop= rectangle from stderr, and returns it as a `-vf`
      # fragment for the main encode pass.
      #
      # Mirrors AutoCropDetector logic that exists in EncodingHelper.cs as a
      # private helper around `cropdetect` invocation.
      #
      # The measurement is cheap (~2 seconds of decode) and idempotent; we
      # memoise per source path + mtime so concurrent jobs don't repeat it.
      module CropDetect
        # Seconds of video to scan. 8 seconds is enough to land on a non-black
        # scene for almost any source while staying cheap.
        SCAN_DURATION = 8
        # Skip the first 30s — opening logos are often letterboxed for stylistic
        # reasons; we want the body of the film.
        SCAN_OFFSET = 30
        # Minimum "interesting" content. If cropdetect suggests cropping more
        # than 40% of the height we assume the detection is bogus (probably
        # detecting a dark scene rather than real black bars).
        MAX_CROP_FRACTION = 0.4

        module_function

        # Returns nil when no crop is needed or detection fails. Otherwise a
        # filter string like "crop=1920:800:0:140".
        def build(job, ffmpeg_path: default_ffmpeg)
          return nil unless job.options.respond_to?(:auto_crop) && job.options.auto_crop
          path = job.media_source.path
          return nil unless path && File.exist?(path)

          rect = measure(path, ffmpeg_path: ffmpeg_path)
          return nil unless rect

          w, h = job.video_stream&.width.to_i, job.video_stream&.height.to_i
          return nil if w.zero? || h.zero?
          # Sanity check — reject huge crops as likely false positives.
          crop_w, crop_h = rect[:w], rect[:h]
          return nil if (1 - crop_h.to_f / h) > MAX_CROP_FRACTION
          return nil if (1 - crop_w.to_f / w) > MAX_CROP_FRACTION
          # Don't bother emitting a filter for sub-2-pixel crops — the encoder
          # rounds to macroblock boundaries anyway and the gain is invisible.
          return nil if (w - crop_w).abs < 2 && (h - crop_h).abs < 2

          "crop=#{rect[:w]}:#{rect[:h]}:#{rect[:x]}:#{rect[:y]}"
        end

        # Public so tests can stub. Returns a hash { w:, h:, x:, y: } or nil.
        def measure(path, ffmpeg_path: default_ffmpeg)
          @cache ||= {}
          key = [path, (File.mtime(path).to_i rescue 0)]
          return @cache[key] if @cache.key?(key)

          cmd = [ffmpeg_path, '-hide_banner', '-nostats', '-loglevel', 'info',
                 '-ss', SCAN_OFFSET.to_s,
                 '-t', SCAN_DURATION.to_s,
                 '-i', path,
                 '-vf', 'cropdetect=24:16:0',
                 '-f', 'null', '-']
          _stdout, stderr, _status = Open3.capture3(*cmd)
          @cache[key] = parse_crop(stderr)
        end

        # cropdetect emits "crop=W:H:X:Y" once per second. The last suggestion
        # is the most stable so we take that.
        def parse_crop(stderr)
          rects = stderr.scan(/crop=(\d+):(\d+):(\d+):(\d+)/)
          return nil if rects.empty?
          last = rects.last
          { w: last[0].to_i, h: last[1].to_i, x: last[2].to_i, y: last[3].to_i }
        end

        def default_ffmpeg
          Jellyfin::Rails.configuration.ffmpeg_path
        end
      end
    end
  end
end
