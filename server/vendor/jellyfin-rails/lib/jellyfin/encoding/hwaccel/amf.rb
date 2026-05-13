require 'jellyfin/encoding/hwaccel/base'

module Jellyfin
  module Encoding
    module Hwaccel
      # AMD Advanced Media Framework (AMF) — Windows / Linux AMD GPUs.
      # Port of EncodingHelper.GetAmdVidFilterChain (cs:4111) + the AMF
      # encoder + decoder paths.
      module Amf
        extend Base
        module_function

        def name = :amf

        def available?(caps)
          caps.supports_hwaccel?('amf') &&
            (caps.supports_encoder?('h264_amf') || caps.supports_encoder?('hevc_amf'))
        end

        def encoder_for(target_codec, caps)
          case target_codec.to_s.downcase
          when 'h264', 'avc'  then caps.supports_encoder?('h264_amf') ? 'h264_amf' : nil
          when 'h265', 'hevc' then caps.supports_encoder?('hevc_amf') ? 'hevc_amf' : nil
          when 'av1'          then caps.supports_encoder?('av1_amf')  ? 'av1_amf'  : nil
          end
        end

        # AMF accepts d3d11va on Windows, vulkan / opencl on Linux. We pick
        # d3d11va by default (matches upstream's preference).
        def decode_args(_job, caps)
          return [] unless caps.supports_hwaccel?('d3d11va')
          ['-hwaccel', 'd3d11va', '-hwaccel_output_format', 'd3d11']
        end

        def filter_chain(job, caps)
          chain = []
          if job.hdr_input? && caps.supports_filter?('tonemap_opencl')
            algo = job.options.tonemapping_algorithm
            peak = job.options.tonemapping_peak
            chain << 'hwmap=derive_device=opencl'
            chain << "tonemap_opencl=tonemap=#{algo}:peak=#{peak}:format=nv12"
            chain << 'hwmap=derive_device=d3d11va:reverse=1'
          end
          chain.empty? ? nil : chain.join(',')
        end

        def encoder_args(job)
          opts = job.options
          ['-quality', amf_quality(opts.encoder_preset),
           '-rc', 'cqp', '-qp_i', opts.h264_crf.to_s,
           '-qp_p', opts.h264_crf.to_s,
           '-qp_b', opts.h264_crf.to_s,
           '-usage', 'transcoding']
        end

        def amf_quality(preset)
          case preset.to_s
          when 'ultrafast', 'superfast', 'veryfast' then 'speed'
          when 'faster', 'fast'                     then 'balanced'
          else 'quality'
          end
        end
      end
    end
  end
end
