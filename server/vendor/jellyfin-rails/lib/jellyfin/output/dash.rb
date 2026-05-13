module Jellyfin
  module Output
    # DASH (Dynamic Adaptive Streaming over HTTP) MPEG-DASH manifest output.
    # Mirrors what Jellyfin's `/Videos/{id}/master.mpd` endpoint produces. The
    # actual segment generation is delegated to ffmpeg's built-in DASH muxer.
    #
    # Important flags:
    #   -seg_duration N      target segment duration in seconds
    #   -use_template 1      generate $Number$ templates instead of explicit URLs
    #   -use_timeline 1      emit SegmentTimeline (precise byte-range hints)
    #   -init_seg_name       filename pattern for the per-track init segment
    #   -media_seg_name      filename pattern for media segments
    module Dash
      module_function

      def output_args(manifest_path:, segment_dir:, segment_length:,
                      window_size: 0, extra_window_size: 0, streaming: false)
        [
          '-f', 'dash',
          '-seg_duration', segment_length.to_s,
          '-use_template', '1',
          '-use_timeline', '1',
          '-window_size', window_size.to_s, # 0 = keep all segments (VOD)
          '-extra_window_size', extra_window_size.to_s,
          '-init_seg_name', 'init-stream$RepresentationID$.m4s',
          '-media_seg_name', 'chunk-stream$RepresentationID$-$Number%05d$.m4s',
          '-streaming', streaming ? '1' : '0',
          '-adaptation_sets', 'id=0,streams=v id=1,streams=a',
          manifest_path
        ]
      end
    end
  end
end
