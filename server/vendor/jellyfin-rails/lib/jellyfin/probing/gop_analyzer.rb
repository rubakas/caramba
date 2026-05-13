require 'json'
require 'open3'

module Jellyfin
  module Probing
    # Detects whether a video stream's GOPs are CLOSED (every I-frame is also an
    # IDR / keyframe) or OPEN (some I-frames reference previous-GOP frames).
    #
    # Why this matters for HLS stream-copy: HLS slices on segment boundaries.
    # If the GOP is open, a P-frame in segment N+1 may reference an I-frame in
    # segment N — and players that arrive at segment N+1 cold can't decode it.
    # Most desktop players tolerate this, smart-TV and embedded decoders often
    # do not. Upstream Jellyfin keys this off the SPS bitstream; we get the
    # same answer cheaper by asking ffprobe for the first few seconds of frame
    # metadata and looking at pict_type vs key_frame.
    #
    # Result semantics:
    #   true  → closed GOP, safe for HLS slicing
    #   false → open GOP, splicing will produce decode errors
    #   nil   → unknown (probe failed, no I-frames found, etc.) — caller decides
    module GopAnalyzer
      # Seconds of frames to read. Five seconds catches at least one full GOP
      # for any sensible source while keeping the ffprobe call fast.
      PROBE_DURATION = 5

      module_function

      def closed?(path, ffprobe_path: default_ffprobe)
        return nil unless path && File.exist?(path)
        cmd = [ffprobe_path, '-v', 'error',
               '-select_streams', 'v:0',
               '-read_intervals', "%+#{PROBE_DURATION}",
               '-show_entries', 'frame=pict_type,key_frame',
               '-of', 'json', path]
        out, _err, status = Open3.capture3(*cmd)
        return nil unless status.success?

        frames = (JSON.parse(out)['frames'] || [])
        i_frames = frames.select { |f| f['pict_type'] == 'I' }
        return nil if i_frames.empty?

        # In ffprobe, key_frame is 1 for IDR (closed-GOP boundary) and 0 for
        # non-IDR I-frames inside an open GOP. If we see *any* non-IDR I-frame
        # the stream has open GOPs.
        i_frames.all? { |f| f['key_frame'].to_i == 1 }
      end

      # Memoizes per-path on the analyzer's caller side. The probe call is
      # idempotent so it's safe to share results across requests.
      def closed_cached(path, ffprobe_path: default_ffprobe)
        @cache ||= {}
        key = [path, File.exist?(path) ? File.mtime(path).to_i : 0]
        @cache[key] ||= closed?(path, ffprobe_path: ffprobe_path)
      end

      def default_ffprobe
        Jellyfin::Rails.configuration.ffprobe_path
      end
    end
  end
end
