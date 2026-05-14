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

        # Mirror of upstream `IsVideoToolboxFullSupported`
        # (EncodingHelper.cs:333). The full GPU-resident chain requires
        # `tonemap_videotoolbox` + `scale_vt` + `yadif_videotoolbox` so the
        # filter graph can run on CVPixelBuffer surfaces end-to-end.
        # Without these, the only alternative is the SW filter `tonemapx`
        # whose system-memory output can't bridge into the HW encoder —
        # ffmpeg fails with "Impossible to convert between the formats
        # supported by the filter 'graph -1 input' and 'auto_scale_0'".
        # Caller (EncodingHelper.resolve_hwaccel) uses this to decide
        # whether the VT backend can cover a given job; HDR jobs on a
        # build that lacks the HW filter set fall back to all-SW.
        def full_chain_supported?(caps)
          caps.supports_hwaccel?('videotoolbox') &&
            caps.supports_filter?('tonemap_videotoolbox') &&
            caps.supports_filter?('scale_vt')
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
          # Only keep decoded frames on CVPixelBuffer surfaces when the
          # full HW filter chain (`tonemap_videotoolbox` + `scale_vt`)
          # can actually consume them. Mirrors upstream
          # EncodingHelper.cs:6982 / 6661 — `useHwSurface = ffmpeg >=
          # 7.0.1 && IsVideoToolboxFullSupported()`, and the
          # `-hwaccel_output_format videotoolbox_vld` token is only
          # emitted when `useHwSurface` is true.
          #
          # Without that gate, every non-HDR transcode kept decoded
          # frames in GPU memory while the rest of the pipeline (SW
          # filter chain → CPU 8-bit input to h264_videotoolbox) needed
          # them in system memory. For 10-bit HEVC sources the resulting
          # auto-conversion path tripped `-allow_sw 1` and silently fell
          # back to libx264 at ~1x realtime. Per-segment serving stalled
          # at exactly one segment_length per request, which is what
          # the user observed (~6 s per .ts on the Network panel).
          args = ['-hwaccel', 'videotoolbox']
          args.concat(['-hwaccel_output_format', 'videotoolbox_vld']) if full_chain_supported?(caps)
          args
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
