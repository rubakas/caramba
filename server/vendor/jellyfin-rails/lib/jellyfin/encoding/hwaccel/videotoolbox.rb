require 'jellyfin/encoding/hwaccel/base'

module Jellyfin
  module Encoding
    module Hwaccel
      # macOS VideoToolbox. Ports the smallest and simplest HW branch in
      # EncodingHelper.cs (~30 LOC). Testable on the dev Mac.
      module Videotoolbox
        extend Base
        module_function

        def name = :videotoolbox

        def available?(caps)
          caps.supports_hwaccel?('videotoolbox') &&
            (caps.supports_encoder?('h264_videotoolbox') || caps.supports_encoder?('hevc_videotoolbox'))
        end

        def encoder_for(target_codec, caps)
          case target_codec.to_s.downcase
          when 'h264', 'avc'
            caps.supports_encoder?('h264_videotoolbox') ? 'h264_videotoolbox' : nil
          when 'h265', 'hevc'
            caps.supports_encoder?('hevc_videotoolbox') ? 'hevc_videotoolbox' : nil
          end
        end

        def decode_args(_job, caps)
          return [] unless caps.supports_hwaccel?('videotoolbox')
          ['-hwaccel', 'videotoolbox']
        end

        def filter_chain(job, caps)
          # tonemap_videotoolbox is the jellyfin-ffmpeg HDR filter for Apple silicon.
          return nil unless job.hdr_input? && caps.supports_filter?('tonemap_videotoolbox')
          peak = job.options.tonemapping_peak
          "tonemap_videotoolbox=tonemap=#{job.options.tonemapping_algorithm}:peak=#{peak}:format=nv12"
        end

        def encoder_args(_job)
          # VideoToolbox uses -b:v from the common path; encoder-specific tuning
          # is minimal compared to libx264 (no preset/tune flags).
          ['-allow_sw', '1']
        end
      end
    end
  end
end
