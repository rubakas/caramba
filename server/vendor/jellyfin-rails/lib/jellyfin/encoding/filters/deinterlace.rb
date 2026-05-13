module Jellyfin
  module Encoding
    module Filters
      # Detects interlaced input and emits the right deinterlace filter.
      # Mirrors EncodingHelper.cs GetDeinterlaceFilter — we support yadif
      # (default), bwdif (better quality), or :off.
      module Deinterlace
        module_function

        def build(job)
          return nil unless job.video_stream&.is_interlaced
          method = job.options.deinterlace_method
          return nil if method == :off

          case method
          when :bwdif then 'bwdif=mode=send_frame:parity=auto:deint=interlaced'
          else             'yadif=mode=send_frame:parity=auto:deint=interlaced'
          end
        end
      end
    end
  end
end
