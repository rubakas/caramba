module Jellyfin
  module Encoding
    # Ports the dynamic-HDR-metadata removal predicates:
    #
    #   - EncodingHelper.IsDoviRemoved      (cs:1469)
    #   - EncodingHelper.IsHdr10PlusRemoved (cs:1475)
    #
    # Both upstream methods boil down to:
    #   1. Is the source carrying this kind of dynamic HDR metadata?
    #   2. Did the encoding pipeline elect to strip it (because the output
    #      codec doesn't support it, or tone-mapping is on, etc.)?
    #
    # We don't have a separate "dynamic HDR removal plan" pipeline in our
    # port — instead we check the live decision directly: tonemapping ON
    # implies the metadata is being removed.
    module DynamicHdrStatus
      module_function

      # Mirrors IsDoviRemoved (cs:1469).
      def dovi_removed?(job)
        return false unless job.video_stream
        return false unless Jellyfin::Encoding::DolbyVision.present?(job.video_stream)
        # Tone-mapping flattens the DV layer. Stream-copy preserves it.
        return false if job.stream_copy_video?
        job.options.enable_tonemapping == true
      end

      # Mirrors IsHdr10PlusRemoved (cs:1475).
      def hdr10plus_removed?(job)
        return false unless job.video_stream
        return false unless Jellyfin::Encoding::Hdr10Plus.present?(job.video_stream)
        return false if job.stream_copy_video?
        job.options.enable_tonemapping == true
      end
    end
  end
end
