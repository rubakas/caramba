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
      #
      # When `keyframe_seconds` is supplied (sorted ascending, in source
      # timeline seconds), the playlist's `#EXTINF` values are derived
      # from real source keyframe boundaries instead of nominal equal
      # lengths. That branch is REQUIRED for stream-copy: ffmpeg's HLS
      # muxer cuts `-c copy` output at source keyframes, producing
      # variable durations (9.1s, 4.0s, 8.7s, ...); a playlist that
      # claims every segment is exactly 6.0s long causes Safari's native
      # HLS engine to throw MEDIA_ERR_DECODE the moment a segment's PTS
      # disagrees with the advertised duration. Mirrors upstream
      # DynamicHlsPlaylistGenerator.cs:34-47 (`IsRemuxingVideo` branch).
      def build(total_duration_seconds:, segment_length_seconds:, seek_seconds: 0,
                segment_extension: 'ts', container: 'ts', init_segment_uri: nil,
                keyframe_seconds: nil)
        remaining = [ total_duration_seconds.to_f - seek_seconds.to_f, 0.0 ].max
        return nil if remaining <= 0 || segment_length_seconds.to_f <= 0

        durations = if keyframe_seconds && !keyframe_seconds.empty?
                      compute_segments_from_keyframes(
                        keyframe_seconds: keyframe_seconds,
                        total_duration_seconds: total_duration_seconds.to_f,
                        seek_seconds: seek_seconds.to_f,
                        segment_length_seconds: segment_length_seconds.to_f
                      )
        else
                      compute_equal_length_segments(remaining, segment_length_seconds.to_f)
        end

        return nil if durations.empty?

        # HLS protocol version: 3 for mpegts, 7 for fmp4 (#EXT-X-MAP requires
        # version 6+; fmp4 segments require version 7). Mirrors
        # DynamicHlsPlaylistGenerator.cs:52.
        hls_version = container.to_s == 'mp4' ? 7 : 3
        # TARGETDURATION must be >= every #EXTINF. With variable
        # keyframe-derived durations the max can exceed the nominal
        # `segment_length_seconds`, so we ceil(max) rather than the
        # nominal value. Mirrors DynamicHlsPlaylistGenerator.cs:63.
        target_duration = durations.max.to_f.ceil

        lines = []
        lines << '#EXTM3U'
        lines << '#EXT-X-PLAYLIST-TYPE:VOD'
        lines << "#EXT-X-VERSION:#{hls_version}"
        lines << "#EXT-X-TARGETDURATION:#{target_duration}"
        lines << '#EXT-X-MEDIA-SEQUENCE:0'
        lines << '#EXT-X-INDEPENDENT-SEGMENTS'

        # fMP4 init segment reference — points at ffmpeg's
        # `-hls_fmp4_init_filename` output. Mirrors upstream
        # DynamicHlsPlaylistGenerator.cs:72-81.
        if init_segment_uri
          lines << %(#EXT-X-MAP:URI="#{init_segment_uri}")
        end

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

      # Mirrors ComputeSegments in DynamicHlsPlaylistGenerator.cs:155-186.
      # Walks the sorted keyframe list emitting a segment cut whenever
      # the next keyframe crosses `desired_cut_time`. `last` tracks the
      # previous cut so each #EXTINF is `keyframe - last`. The trailing
      # remainder (last keyframe → end of source) is emitted as a final
      # short segment.
      #
      # When ffmpeg is started with `-ss <seek_seconds>`, segment 0 of
      # its HLS output corresponds to the first source keyframe at or
      # after `seek_seconds`. We translate the keyframe timeline into a
      # post-seek coordinate system before computing cuts so durations
      # match what the muxer will produce.
      def compute_segments_from_keyframes(keyframe_seconds:, total_duration_seconds:,
                                          seek_seconds:, segment_length_seconds:)
        # Drop keyframes the seek skips over, then re-base to t=0.
        adjusted = keyframe_seconds.drop_while { |k| k.to_f < seek_seconds.to_f }
        adjusted = adjusted.map { |k| k.to_f - seek_seconds.to_f }
        return [] if adjusted.empty?

        # If the source ends before the last keyframe we know about
        # (mis-muxed file or rounding), treat the last keyframe as the
        # implied end. Mirrors upstream's bounds correction at
        # DynamicHlsPlaylistGenerator.cs:157-160.
        effective_total = [ total_duration_seconds.to_f - seek_seconds.to_f, adjusted.last ].max

        out = []
        last_cut = 0.0
        desired_cut = segment_length_seconds.to_f
        adjusted.each do |k|
          next if k <= last_cut
          if k >= desired_cut
            out << (k - last_cut)
            last_cut = k
            desired_cut += segment_length_seconds.to_f
          end
        end
        tail = effective_total - last_cut
        out << tail if tail > 0.001
        out
      end
    end
  end
end
