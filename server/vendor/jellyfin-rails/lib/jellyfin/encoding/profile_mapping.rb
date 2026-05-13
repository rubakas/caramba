module Jellyfin
  module Encoding
    # H.264 / H.265 profile selection. Maps (input profile, client capabilities,
    # output codec, bit depth) → ffmpeg `-profile:v` value.
    #
    # Ports the decision tree from EncodingHelper.GetH264Profile / GetH265Profile.
    # The full upstream has finer-grained rules around DLNA constraints which
    # we skip; this covers the common-case 99%.
    module ProfileMapping
      H264_PROFILES   = %w[baseline main high high10 high422 high444].freeze
      H265_PROFILES   = %w[main main10 main12 mainstillpicture rext].freeze

      module_function

      def for_h264(job, capabilities: nil)
        bit_depth = job.video_stream&.bit_depth.to_i
        client_profiles = job.options.respond_to?(:client_h264_profiles) && job.options.client_h264_profiles || H264_PROFILES

        # Above 8-bit, force at least high10.
        candidates = bit_depth >= 10 ? %w[high10 high422] : %w[high main baseline]
        candidates.find { |p| client_profiles.include?(p) } || candidates.first
      end

      def for_h265(job, capabilities: nil)
        bit_depth = job.video_stream&.bit_depth.to_i
        return 'main12' if bit_depth >= 12
        return 'main10' if bit_depth >= 10
        'main'
      end

      def for(job, capabilities: nil)
        codec = job.output_video_codec.to_s.downcase
        case codec
        when 'h264', 'libx264', 'h264_videotoolbox', 'h264_vaapi', 'h264_nvenc', 'h264_qsv'
          for_h264(job, capabilities: capabilities)
        when 'h265', 'hevc', 'libx265', 'hevc_videotoolbox', 'hevc_vaapi', 'hevc_nvenc', 'hevc_qsv'
          for_h265(job, capabilities: capabilities)
        end
      end
    end
  end
end
