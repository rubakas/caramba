module Jellyfin
  module Encoding
    # Port of EncodingHelper.GetOutputFFlags (cs:7608). Builds the `-fflags`
    # argument list applied AFTER the input has been opened — controls
    # output-side PTS generation and mux behaviour.
    #
    # Upstream sets `+genpts` only when `state.GenPtsOutput` is true. That
    # flag is computed elsewhere from the segment type + codec combination.
    # We track it on EncodingJobInfo and let the caller decide.
    module OutputFflags
      module_function

      # Returns an args array (possibly empty) to splice AFTER the output
      # codec but BEFORE the output destination.
      def args(job)
        flags = []
        flags << '+genpts' if gen_pts_output?(job)
        flags.empty? ? [] : ['-fflags', flags.join]
      end

      # Mirrors EncodingJobInfo.GenPtsOutput. Upstream sets this true when:
      #   - output is HLS / mpegts
      #   - source has unreliable timestamps (live, container-resync needed)
      # We use the simpler heuristic: emit +genpts whenever output is segmented.
      def gen_pts_output?(job)
        return true if job.respond_to?(:hls?) && job.hls?
        false
      end
    end
  end
end
