require 'jellyfin/encoding/hwaccel/base'
require 'jellyfin/encoding/hwaccel/decoder'

module Jellyfin
  module Encoding
    module Hwaccel
      # Intel QuickSync. Port of upstream Jellyfin's QSV pipeline:
      # - Device setup: GetQsvDeviceArgs (EncodingHelper.cs:938) chains
      #   VAAPI → QSV on Linux so vpp_qsv and h264_qsv share a backing
      #   surface pool.
      # - Decoder selection: GetHwDecoderName (cs:6464) picks a per-codec
      #   QSV decoder (h264_qsv, hevc_qsv, vp9_qsv, av1_qsv, mpeg2_qsv)
      #   when the source codec has one available.
      # - Two filter-chain shapes (cs:4730-4807):
      #     SW decode → CPU nv12 from `format=nv12` (no hwupload —
      #     h264_qsv accepts CPU NV12 input and uploads internally).
      #     HW decode → QSV surfaces from the decoder, `vpp_qsv` performs
      #     any scale + format conversion in-place on the iGPU.
      module Qsv
        extend Base
        module_function

        QSV_ALIAS   = 'qs'.freeze
        VAAPI_ALIAS = 'va'.freeze

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

        # Pre-input args. Sets up the VAAPI device the iHD driver runs on,
        # then derives a QSV device from it and pins the filter graph to
        # that QSV device — mirrors upstream `GetQsvDeviceArgs` on Linux
        # (EncodingHelper.cs:938-960). When the source codec also has a
        # QSV decoder, request HW decode with QSV-surface output so the
        # main filter chain can hand frames straight to `vpp_qsv` / the
        # encoder without a CPU round-trip.
        def decode_args(job, caps)
          return [] unless caps.supports_hwaccel?('qsv')
          device = vaapi_device
          args = [
            '-init_hw_device', "vaapi=#{VAAPI_ALIAS}:#{device},driver=iHD,kernel_driver=i915",
            '-init_hw_device', "qsv=#{QSV_ALIAS}@#{VAAPI_ALIAS}",
            '-filter_hw_device', QSV_ALIAS
          ]
          if hw_decode?(job, caps)
            args.concat([ '-hwaccel', 'qsv', '-hwaccel_output_format', 'qsv' ])
          end
          args
        end

        def filter_chain(job, caps)
          if hw_decode?(job, caps)
            hw_decode_chain(job)
          else
            sw_decode_chain(job)
          end
        end

        def encoder_args(_job)
          [ '-preset', 'medium', '-look_ahead', '0' ]
        end

        # ── helpers ────────────────────────────────────────────────────

        # True when ffmpeg has a QSV decoder for THIS source's codec and
        # caps advertise it. Falls through to false (SW decode) for codecs
        # that the iGPU's media engine doesn't fixed-function decode —
        # ffmpeg still uses the iGPU for the encode side via h264_qsv.
        def hw_decode?(job, caps)
          return false unless caps.respond_to?(:supports_decoder?)
          codec = job.video_stream&.codec
          return false if codec.nil?
          bit_depth = job.video_stream&.bit_depth || 8
          !Decoder.for(
            accel_type: :qsv,
            codec: codec,
            bit_depth: bit_depth,
            capabilities: caps
          ).nil?
        end

        # HW-decode branch (mirrors EncodingHelper.cs:4760-4807). Input is
        # already a QSV surface; vpp_qsv handles scale + format in one
        # GPU-side pass. h264_qsv consumes the QSV surface directly.
        def hw_decode_chain(job)
          out_h = job.output_height
          if out_h
            "vpp_qsv=w=-2:h='min(#{out_h},ih)':format=nv12"
          else
            'vpp_qsv=format=nv12'
          end
        end

        # SW-decode branch (mirrors EncodingHelper.cs:4730-4757). Input is
        # CPU memory (yuv420p / yuv420p10le); we scale + format-convert in
        # software and hand CPU NV12 to h264_qsv, which uploads internally
        # — no explicit hwupload needed.
        def sw_decode_chain(job)
          parts = []
          parts << "scale=-2:'min(#{job.output_height},ih)':flags=lanczos" if job.output_height
          parts << 'format=nv12'
          parts.join(',')
        end

        def vaapi_device
          Jellyfin::Rails.configuration.respond_to?(:vaapi_device) &&
            Jellyfin::Rails.configuration.vaapi_device ||
            ENV.fetch('JELLYFIN_VAAPI_DEVICE', '/dev/dri/renderD128')
        end
      end
    end
  end
end
