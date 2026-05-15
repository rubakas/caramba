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

        def decode_args(job, caps)
          return [] unless caps.supports_hwaccel?('videotoolbox')
          # `-hwaccel_output_format videotoolbox_vld` keeps decoded
          # frames on CVPixelBuffer surfaces so that the HW filter chain
          # (`tonemap_videotoolbox`, `scale_vt`) can consume them
          # directly. We only emit it when THIS job will actually run
          # such a chain — that is, when `filter_chain(job, caps)`
          # returns a non-nil HW filter (today, only the HDR tonemap
          # path).
          #
          # Mirrors upstream EncodingHelper.cs:6661/6982 — there the
          # flag is gated on `useHwSurface`, which is itself only used
          # when the job's filter chain will run on HW surfaces.
          #
          # Why the gate matters: when there are no HW filters, frames
          # need to be in system memory so the SW filter chain (and the
          # `h264_videotoolbox` encoder's CPU input path) can consume
          # them. With `-hwaccel_output_format videotoolbox_vld` set,
          # GPU-resident 10-bit `p010` frames couldn't bridge into the
          # SW chain; `-allow_sw 1` then silently fell back to libx264
          # at ~1x realtime. Each HLS segment took an entire
          # segment_length (~6 s) of wall time to produce — exactly
          # the symptom the user observed.
          args = [ '-hwaccel', 'videotoolbox' ]
          args.concat([ '-hwaccel_output_format', 'videotoolbox_vld' ]) if hw_filter_chain_active?(job, caps)
          args
        end

        # True when this job's filter chain will actually run on HW
        # surfaces — i.e. `filter_chain(job, caps)` returns a non-nil
        # HW filter expression. Today this is only the HDR tonemap
        # path; when scale/burn/etc. are ported to HW filters they'd
        # also flip this on.
        def hw_filter_chain_active?(job, caps)
          full_chain_supported?(caps) && !filter_chain(job, caps).nil?
        end

        def filter_chain(job, caps)
          # tonemap_videotoolbox is the jellyfin-ffmpeg HDR filter for Apple silicon.
          return nil unless job.hdr_input? && caps.supports_filter?('tonemap_videotoolbox')
          peak = job.options.tonemapping_peak
          # `tonemap_videotoolbox` runs on CVPixelBuffer surfaces and emits
          # videotoolbox-tagged nv12 (GPU memory). `hwdownload + format=nv12`
          # brings the frames back to system memory so the downstream
          # encoder (or any SW filter / `-pix_fmt yuv420p` auto-scale) can
          # consume them. Without the download leg ffmpeg fails with
          #   Impossible to convert between the formats supported by the
          #   filter 'Parsed_tonemap_videotoolbox_0' and the filter
          #   'auto_scale_0'
          # and nothing is written to the output — the symptom users see is
          # the init segment endpoint timing out at 10 s on every HDR
          # transcode (Aladdin / Ratatouille / Iron Giant 4K HDR rips).
          # Mirrors upstream Jellyfin's `EncodingHelper.GetHwTonemapFilter`
          # (EncodingHelper.cs ~6705) which always closes the HW filter
          # block with `hwdownload` + `format=…` so the encoder side stays
          # on system memory.
          "tonemap_videotoolbox=tonemap=#{job.options.tonemapping_algorithm}:peak=#{peak}:format=nv12,hwdownload,format=nv12"
        end

        def encoder_args(_job)
          # VideoToolbox uses -b:v from the common path; encoder-specific
          # tuning is minimal compared to libx264 (no preset/tune flags).
          #
          # We intentionally do NOT pass `-allow_sw 1`. Despite the name
          # implying "fall back to SW only if HW fails", on Apple Silicon
          # + jellyfin-ffmpeg's h264_videotoolbox it preemptively steers
          # into the SW path whenever the input pixel format isn't a
          # bit-exact match for the encoder's preferred format. For a
          # 10-bit HEVC source transcoding to 8-bit H.264, this fires
          # every time — `-pix_fmt yuv420p` should make ffmpeg auto-
          # insert a 10→8 conversion in front of the HW encoder, but
          # `-allow_sw 1` skips the HW init entirely and routes through
          # SW. Measured cost on the user's `Office S01E03` HEVC 10-bit
          # MKV: 60s of source took 19.9s with `-allow_sw 1` (~3× wall,
          # 174% CPU) vs 9.8s without (~6× wall, 107% CPU). The 174%
          # CPU pattern matches multi-threaded libx264; the 107%
          # matches HW encode on one orchestration thread.
          []
        end
      end
    end
  end
end
