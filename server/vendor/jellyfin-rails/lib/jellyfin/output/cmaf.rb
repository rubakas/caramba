module Jellyfin
  module Output
    # CMAF (Common Media Application Format, ISO/IEC 23000-19) lets a single
    # set of fragmented-MP4 segments serve BOTH HLS and DASH clients. The
    # bytes on disk are identical; only the manifests differ. Storage drops
    # ~50% when offering both protocols.
    #
    # Recipe:
    #   1. Emit ffmpeg output as fragmented MP4 (`-f dash` OR
    #      `-hls_segment_type fmp4`). Both muxers can write to the SAME
    #      segment files if you point them at the same directory and use
    #      matching `init_seg_name`/`media_seg_name` patterns.
    #   2. Write the HLS playlist referencing those files.
    #   3. Write the DASH manifest referencing those files.
    #
    # The simplest plumbing: a single ffmpeg invocation that uses the dash
    # muxer to lay out files, then a second pass that scans the directory and
    # emits a parallel HLS playlist over the same .m4s files.
    module Cmaf
      module_function

      # ffmpeg args that produce CMAF-compatible fmp4 segments. The DASH
      # muxer is the canonical producer; HLS playlist generation runs over
      # the same files afterwards.
      def output_args(manifest_path:, segment_dir:, segment_length:)
        [
          '-f', 'dash',
          '-seg_duration', segment_length.to_s,
          '-use_template', '1', '-use_timeline', '1',
          '-init_seg_name', 'init-$RepresentationID$.m4s',
          '-media_seg_name', '$RepresentationID$-$Number%05d$.m4s',
          '-hls_playlist', '1',                      # generate HLS playlist alongside DASH
          '-hls_master_name', 'master.m3u8',
          '-adaptation_sets', 'id=0,streams=v id=1,streams=a',
          manifest_path
        ]
      end

      # Scans a CMAF directory and returns the segment filenames per
      # representation. Useful when running the HLS pass over an existing
      # DASH-laid-out tree.
      def list_segments(segment_dir, representation: '0')
        Dir.glob(File.join(segment_dir, "#{representation}-*.m4s")).sort
      end
    end
  end
end
