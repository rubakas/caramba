module Jellyfin
  module Encoding
    # Port of EncodingHelper.GetNegativeMapArgsByFilters (cs:3121). When the
    # filter chain consumes a stream (e.g., `[0:v][0:s]overlay[v]` consumes
    # both video and subtitle inputs), ffmpeg's auto-map logic would also
    # try to map the same source streams to the output AGAIN. The negative
    # map argument `-map -0:<index>` tells ffmpeg to skip the original
    # stream.
    #
    # Upstream emits it when the filter chain is "complex" — i.e., uses
    # `-filter_complex`. Our SW filter chain uses `-vf`, which doesn't need
    # the negative-map fixup; the HW filter chains that use complex graphs
    # do need it.
    module NegativeMap
      module_function

      def args(job:, video_process_filters: '')
        return [] unless job.video_stream
        return [] unless video_process_filters.to_s.include?('-filter_complex')

        video_idx = job.media_source.streams.index { |s| s.index == job.video_stream.index }
        return [] unless video_idx
        ['-map', "-0:#{video_idx}"]
      end
    end
  end
end
