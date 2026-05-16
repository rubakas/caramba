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
          [ '-hwaccel', 'qsv', '-hwaccel_output_format', 'qsv' ]
        end

        def filter_chain(job, _caps)
          # `format=nv12|qsv` accepts either CPU-side nv12 or a QSV surface;
          # anything else (notably the yuv420p coming out of a SW H.264
          # decode, when the source codec lacks a QSV decoder or QSV decode
          # is unavailable) gets converted to nv12 before `hwupload`.
          # Without this prefix, hwupload sees yuv420p and ffmpeg
          # auto-inserts an `auto_scale` filter that can't bridge software
          # YUV to a QSV hardware surface, blowing up with
          # "Impossible to convert between the formats supported by the
          # filter 'Parsed_hwupload_0' and the filter 'auto_scale_0'".
          # Mirrors Vaapi#filter_chain (jellyfin-rails) and the SW-decode
          # branch of upstream EncodingHelper.cs:4750 which appends
          # `format=nv12` before the eventual hwupload.
          chain = [ 'format=nv12|qsv,hwupload=extra_hw_frames=64' ]
          if job.output_height
            chain << "scale_qsv=-2:'min(#{job.output_height},ih)'"
          end
          chain.join(',')
        end

        def encoder_args(_job)
          [ '-preset', 'medium', '-look_ahead', '0' ]
        end
      end
    end
  end
end
