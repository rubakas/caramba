module Jellyfin
  module Output
    # Progressive MP4 output. One file, faststart-shuffled so playback can
    # begin before the whole file downloads. Used by:
    #   - download endpoints (single-file delivery)
    #   - Apple-prefix-compatible clients that don't speak HLS yet
    module Mp4
      module_function

      def output_args(output_path:, fragmented: false)
        flags = if fragmented
                  # CMAF-compatible fragmented MP4 — small moov + interleaved fragments.
                  %w[+frag_keyframe +empty_moov +default_base_moof]
                else
                  # Faststart relocates the moov atom to the front so streaming
                  # players can begin playback while bytes are still arriving.
                  %w[+faststart]
                end

        [
          '-f', 'mp4',
          '-movflags', flags.join,
          output_path
        ]
      end
    end
  end
end
