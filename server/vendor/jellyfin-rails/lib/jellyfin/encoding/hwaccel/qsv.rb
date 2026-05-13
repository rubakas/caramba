require 'jellyfin/encoding/hwaccel/base'

module Jellyfin
  module Encoding
    module Hwaccel
      # Intel QuickSync. Common-path port (~80 LOC upstream); we cover Linux
      # via VAAPI bridge by default. Windows D3D11VA interop is deferred.
      module Qsv
        extend Base
        module_function

        def name = :qsv

        def available?(caps)
          caps.supports_hwaccel?('qsv') &&
            (caps.supports_encoder?('h264_qsv') || caps.supports_encoder?('hevc_qsv'))
        end

        def encoder_for(target_codec, caps)
          case target_codec.to_s.downcase
          when 'h264', 'avc'  then caps.supports_encoder?('h264_qsv') ? 'h264_qsv' : nil
          when 'h265', 'hevc' then caps.supports_encoder?('hevc_qsv') ? 'hevc_qsv' : nil
          when 'av1'          then caps.supports_encoder?('av1_qsv')  ? 'av1_qsv'  : nil
          end
        end

        def decode_args(_job, caps)
          return [] unless caps.supports_hwaccel?('qsv')
          ['-hwaccel', 'qsv', '-hwaccel_output_format', 'qsv']
        end

        def filter_chain(job, _caps)
          chain = ['hwupload=extra_hw_frames=64']
          if job.output_height
            chain << "scale_qsv=-2:'min(#{job.output_height},ih)'"
          end
          chain.join(',')
        end

        def encoder_args(_job)
          ['-preset', 'medium', '-look_ahead', '0']
        end
      end
    end
  end
end
