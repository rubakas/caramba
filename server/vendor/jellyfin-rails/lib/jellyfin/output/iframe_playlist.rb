module Jellyfin
  module Output
    # I-frame trickplay playlist generation. ffmpeg writes a separate playlist
    # whose entries reference byte ranges within the main segments containing
    # only the keyframes — used by HLS players for scrubbing previews.
    #
    # Two modes:
    #   :sidecar    a separate .m3u8 alongside the main one
    #   :merged     written into the master playlist via #EXT-X-I-FRAME-STREAM-INF
    module IframePlaylist
      module_function

      # Returns ffmpeg arguments to emit an I-frame playlist next to the main
      # HLS playlist. Used in conjunction with the regular HLS output args.
      def output_args(iframe_playlist_path:)
        # `hls_flags=i_frames_only` makes ffmpeg also write an I-frame-only
        # playlist. The path is configured by `hls_iframe_playlist` since 6.x.
        [
          '-hls_flags', 'i_frames_only',
          '-hls_iframe_playlist', iframe_playlist_path
        ]
      end
    end
  end
end
