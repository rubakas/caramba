module Jellyfin
  module Encoding
    module Filters
      # Anamorphic correction. When sample_aspect_ratio ≠ 1:1, output looks
      # squashed/stretched unless we apply `setsar=1` after scaling to a
      # display-square pixel grid. Mirrors EncodingHelper.cs handling of
      # SAR/DAR normalization.
      module Anamorphic
        module_function

        def build(job)
          v = job.video_stream
          return nil unless v
          sar = v.sample_aspect_ratio.to_s
          return nil if sar.empty? || sar == '1:1' || sar == '0:1'
          'setsar=1'
        end
      end
    end
  end
end
