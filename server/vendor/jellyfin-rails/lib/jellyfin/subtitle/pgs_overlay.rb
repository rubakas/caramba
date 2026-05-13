module Jellyfin
  module Subtitle
    # Builds the ffmpeg complex_filter graph that burns PGS / DVB / DVD bitmap
    # subtitles onto the video. Mirrors EncodingHelper.cs GetGraphicalSubCanvasSize
    # plus the overlay chain the controller would emit.
    #
    # The graph (for a single sub input stream `0:s:<si>`):
    #
    #   [0:s:<si>]scale=W:H:flags=lanczos,format=yuva420p[subs];
    #   [vid][subs]overlay=shortest=1,format=yuv420p[v]
    #
    # `vid` is whatever label upstream filters produced (typically [v] from the
    # video filter chain). We scale the subs to match the OUTPUT video canvas,
    # not the source, so subtitle positioning stays correct under downscale.
    module PgsOverlay
      module_function

      # Returns a 2-element array: [extra_input_args, complex_filter_chain_string]
      # The chain is prefixed with `;` since it's appended to the existing graph.
      #
      # `vid_label` is the label of the upstream video output (e.g., 'v').
      # `sub_input_index` is the ffmpeg stream specifier without the leading 0.
      def build(job, vid_label: 'v', sub_input_index: nil)
        return [[], nil] unless job.burn_subtitles? && graphical?(job.subtitle_stream)

        si = sub_input_index || subtitle_si_index(job)
        w  = job.output_width  || job.video_stream&.width  || 1920
        h  = job.output_height || job.video_stream&.height || 1080

        chain = "[0:s:#{si}]scale=#{w}:#{h}:flags=lanczos,format=yuva420p[subs];" \
                "[#{vid_label}][subs]overlay=shortest=1,format=yuv420p[vout]"

        [[], chain]
      end

      def graphical?(stream)
        return false unless stream
        %w[hdmv_pgs_subtitle pgssub dvd_subtitle dvbsub].include?(stream.codec.to_s.downcase)
      end

      def subtitle_si_index(job)
        subs = job.media_source.subtitle_streams
        subs.index { |s| s.index == job.subtitle_stream.index } || 0
      end
    end
  end
end
