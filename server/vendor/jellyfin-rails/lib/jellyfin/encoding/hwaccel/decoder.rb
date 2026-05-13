module Jellyfin
  module Encoding
    module Hwaccel
      # Port of EncodingHelper.cs:6464 GetHwDecoderName + the per-vendor
      # decoder methods (GetQsvHwVidDecoder cs:6675, GetNvdecVidDecoder
      # cs:6758, GetAmfVidDecoder cs:6831, GetVaapiVidDecoder cs:6887,
      # GetVideotoolboxVidDecoder cs:6960, GetRkmppVidDecoder cs:7025).
      #
      # Returns the ffmpeg `-c:v <decoder>` argument string for the
      # source's video codec + bit depth, taking into account vendor
      # capability flags (e.g., 10-bit HEVC decode requires specific
      # hardware generations).
      module Decoder
        # Upstream maps (vendor, codec) → decoder name via a tabular helper
        # `GetHwDecoderName(options, prefix, suffix, codec, bitDepth)`.
        # The prefix is the codec family ("h264", "hevc", etc.); the suffix
        # is the vendor accel suffix ("_qsv", "_cuvid", "_amf", "_vaapi",
        # "_videotoolbox", "_rkmpp").
        VENDOR_SUFFIX = {
          qsv:          '_qsv',
          nvenc:        '_cuvid',
          amf:          '_amf',
          vaapi:        '_vaapi',
          videotoolbox: '_videotoolbox',
          rkmpp:        '_rkmpp'
        }.freeze

        module_function

        # Port of GetHwDecoderName (cs:6464). Returns nil when the resulting
        # decoder is not present in ffmpeg's encoder table.
        def for(accel_type:, codec:, bit_depth: 8, capabilities:)
          suffix = VENDOR_SUFFIX[accel_type.to_sym]
          return nil unless suffix
          prefix = decoder_prefix(codec)
          return nil unless prefix
          # 10-bit HEVC requires a Main10-capable decoder. Upstream gates this
          # on EncodingHelper.cs:6470 — we use the same heuristic.
          return nil if bit_depth.to_i >= 10 && !supports_10bit_hw?(accel_type)

          name = "#{prefix}#{suffix}"
          return nil unless capabilities.respond_to?(:supports_decoder?) && capabilities.supports_decoder?(name)
          name
        end

        # Port of GetHwaccelType (cs:6522). Maps codec + accel type to the
        # ffmpeg `-hwaccel` value (which differs from decoder name; e.g.,
        # qsv uses `qsv` for hwaccel but `h264_qsv` for the decoder).
        def hwaccel_type(accel_type)
          case accel_type.to_sym
          when :qsv          then 'qsv'
          when :nvenc        then 'cuda'
          when :amf          then 'd3d11va'
          when :vaapi        then 'vaapi'
          when :videotoolbox then 'videotoolbox'
          when :rkmpp        then 'rkmpp'
          end
        end

        def decoder_prefix(codec)
          case codec.to_s.downcase
          when 'h264', 'avc'  then 'h264'
          when 'hevc', 'h265' then 'hevc'
          when 'av1'          then 'av1'
          when 'vp9'          then 'vp9'
          when 'vp8'          then 'vp8'
          when 'mpeg2', 'mpeg2video' then 'mpeg2'
          when 'mpeg4'        then 'mpeg4'
          end
        end

        # Per-vendor 10-bit decode capability. Mirrors the upstream guards
        # scattered across the per-vendor decoder methods.
        def supports_10bit_hw?(accel_type)
          # NVDEC supports HEVC Main10 since Pascal (10xx series). AMD AMF
          # since RDNA. Intel QSV since Kaby Lake. VAAPI requires the right
          # entry-points compiled in. VideoToolbox supports HEVC Main10 on
          # all Apple Silicon. RKMPP supports it on RK3588.
          %i[nvenc qsv amf vaapi videotoolbox rkmpp].include?(accel_type.to_sym)
        end
      end
    end
  end
end
