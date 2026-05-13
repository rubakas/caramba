module Jellyfin
  module Output
    # Live HLS playlist builder. Port of the live-stream branch of
    # `DynamicHlsController.GetLiveHlsStream` (cs:168) and the playlist
    # construction inside `DynamicHlsHelper.GetMasterPlaylistInternal` when
    # `state.IsSegmentedLiveStream == true`.
    #
    # A live playlist:
    #   - has `#EXT-X-PLAYLIST-TYPE:LIVE` (vs `EVENT` for finite VOD)
    #   - omits `#EXT-X-ENDLIST` while the stream continues
    #   - uses `#EXT-X-MEDIA-SEQUENCE` to identify the sliding window's start
    #   - typically lists only the last N segments (N = `hls_list_size`)
    #
    # ffmpeg writes these automatically when given `-hls_playlist_type live`
    # and `-hls_list_size`; this module exposes a Ruby renderer for cases
    # where the caller wants to hand-build the playlist (e.g. proxying a
    # network source).
    module LiveHls
      DEFAULT_LIST_SIZE = 6

      module_function

      # Renders a sliding-window playlist for live streams. `segments` is an
      # array of { uri:, duration:, sequence: } hashes; we emit the last
      # `list_size` of them with the appropriate media-sequence header.
      def render(segments:, target_duration:, list_size: DEFAULT_LIST_SIZE)
        window = segments.last(list_size)
        first_seq = window.first ? window.first[:sequence].to_i : 0

        lines = ['#EXTM3U',
                 '#EXT-X-VERSION:6',
                 "#EXT-X-TARGETDURATION:#{target_duration}",
                 '#EXT-X-PLAYLIST-TYPE:LIVE',
                 "#EXT-X-MEDIA-SEQUENCE:#{first_seq}",
                 '#EXT-X-INDEPENDENT-SEGMENTS']

        window.each do |seg|
          lines << "#EXTINF:#{format('%.3f', seg[:duration])},"
          lines << seg[:uri]
        end
        # No #EXT-X-ENDLIST while the stream is live — upstream emits it only
        # when the source signals end-of-feed.
        lines.join("\n") + "\n"
      end

      # ffmpeg flags appended to the HLS muxer for live mode. Mirrors the
      # `-hls_playlist_type live` + `-hls_list_size` combination the upstream
      # uses (see EncodingHelper.cs around line 7385).
      def output_args(list_size: DEFAULT_LIST_SIZE)
        ['-hls_playlist_type', 'live',
         '-hls_list_size', list_size.to_s,
         '-hls_flags', 'delete_segments+independent_segments+temp_file']
      end
    end
  end
end
