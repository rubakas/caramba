require 'jellyfin/encoding/hwaccel/base'

module Jellyfin
  module Encoding
    module Hwaccel
      # Rockchip Media Process Platform (RKMPP) — used on RK3399 / RK3568 /
      # RK3588 SBCs (Pi-class ARM boards with hardware video blocks).
      # Port of EncodingHelper.GetRkmppVidDecoder (cs:7025) + the RKMPP
      # encoder + filter paths.
      module Rkmpp
        extend Base
        module_function

        def name = :rkmpp

        def available?(caps)
          caps.supports_hwaccel?('rkmpp') &&
            (caps.supports_encoder?('h264_rkmpp') || caps.supports_encoder?('hevc_rkmpp'))
        end

        def encoder_for(target_codec, caps)
          case target_codec.to_s.downcase
          when 'h264', 'avc'  then caps.supports_encoder?('h264_rkmpp') ? 'h264_rkmpp' : nil
          when 'h265', 'hevc' then caps.supports_encoder?('hevc_rkmpp') ? 'hevc_rkmpp' : nil
          end
        end

        def decode_args(_job, caps)
          return [] unless caps.supports_hwaccel?('rkmpp')
          ['-hwaccel', 'rkmpp', '-hwaccel_output_format', 'drm_prime', '-afbc', 'rga']
        end

        def filter_chain(job, caps)
          chain = []
          # Rockchip's RGA (raster graphics accelerator) handles scale + format
          # conversion on the GPU. Tonemap requires a special drm_prime path.
          if job.hdr_input? && caps.supports_filter?('tonemap_rkrga')
            algo = job.options.tonemapping_algorithm
            peak = job.options.tonemapping_peak
            chain << "tonemap_rkrga=tonemap=#{algo}:peak=#{peak}:format=nv12"
          end
          chain.empty? ? nil : chain.join(',')
        end

        def encoder_args(job)
          opts = job.options
          ['-rc_mode', 'CBR', '-quality_min', '70', '-quality_max', '90',
           '-preset', opts.encoder_preset]
        end
      end
    end
  end
end
