module Jellyfin
  module Output
    # Pre-generates a complete VOD variant playlist with every segment listed
    # + EXT-X-ENDLIST. Mirrors upstream
    # Jellyfin.MediaEncoding.Hls/Playlist/DynamicHlsPlaylistGenerator.cs#CreateMainPlaylist
    # (and its ComputeEqualLengthSegments helper).
    #
    # Why we don't serve ffmpeg's in-progress playlist directly:
    # ffmpeg's HLS muxer streams the playlist file as it produces segments
    # — with `-hls_playlist_type=event` (or `live`), there's no
    # EXT-X-ENDLIST until the encode finishes. Safari's native HLS engine
    # treats EVENT-without-ENDLIST as a live stream, computes duration from
    # what's already on disk, and refuses to start playback for transcodes
    # that take >1-2s to produce the first segments (HEVC→H.264 of a 4K
    # source is exactly that case). The symptom is a spinner that never
    # clears, followed by MEDIA_ERR_SRC_NOT_SUPPORTED (code 4). hls.js
    # tolerates EVENT playlists, which is why Chrome plays the same stream.
    #
    # ffmpeg still encodes lazily; the segment endpoint waits for each
    # file to exist via SegmentWaiter. The pre-generated playlist just
    # tells Safari the full timeline upfront.
    module VodPlaylistGenerator
      module_function

      TICKS_PER_SECOND = 10_000_000

      # Builds the VOD variant playlist string.
      #
      # `total_duration_seconds` is the source's total run time. `seek_seconds`
      # is the offset ffmpeg is starting from (so the playlist only covers
      # `total - seek` worth of content). `segment_length_seconds` matches
      # the value passed to ffmpeg's `-hls_time`.
      def build(total_duration_seconds:, segment_length_seconds:, seek_seconds: 0,
                segment_extension: 'ts', container: 'ts')
        remaining = [ total_duration_seconds.to_f - seek_seconds.to_f, 0.0 ].max
        return nil if remaining <= 0 || segment_length_seconds.to_f <= 0

        durations = compute_equal_length_segments(remaining, segment_length_seconds.to_f)

        # HLS protocol version: 3 for mpegts, 7 for fmp4 (#EXT-X-MAP requires
        # version 6+; fmp4 segments require version 7). Mirrors
        # DynamicHlsPlaylistGenerator.cs:52.
        hls_version = container.to_s == 'mp4' ? 7 : 3

        lines = []
        lines << '#EXTM3U'
        lines << '#EXT-X-PLAYLIST-TYPE:VOD'
        lines << "#EXT-X-VERSION:#{hls_version}"
        lines << "#EXT-X-TARGETDURATION:#{segment_length_seconds.to_f.ceil}"
        lines << '#EXT-X-MEDIA-SEQUENCE:0'
        lines << '#EXT-X-INDEPENDENT-SEGMENTS'

        durations.each_with_index do |d, i|
          lines << format('#EXTINF:%.6f,', d)
          lines << "#{i}.#{segment_extension}"
        end

        lines << '#EXT-X-ENDLIST'
        lines.join("\n") + "\n"
      end

      # Mirrors ComputeEqualLengthSegments in
      # DynamicHlsPlaylistGenerator.cs:188-214 — splits the runtime into
      # equal-length segments with the remainder as the final entry.
      def compute_equal_length_segments(total_seconds, segment_length_seconds)
        whole = (total_seconds / segment_length_seconds).floor
        remainder = total_seconds - (whole * segment_length_seconds)
        out = Array.new(whole, segment_length_seconds)
        # 1ms guard against a near-zero tail segment that some demuxers reject.
        out << remainder if remainder > 0.001
        out
      end
    end
  end
end
