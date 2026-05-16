require 'jellyfin/encoding/hwaccel/base'
require 'jellyfin/encoding/hwaccel/decoder'
require 'jellyfin/encoding/bitrate'

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

        # Encoder args for h264_qsv / hevc_qsv. Mirrors upstream Jellyfin's
        # default QSV path (EncodingHelper.cs:1761 + cs:1609-1644).
        #
        # **Rate-control mode: bitrate-targeted VBR, not ICQ.** This is
        # the most important quality knob. ICQ (`-global_quality`) is
        # quality-targeted — on complex scenes it drops bitrate
        # aggressively, producing visibly worse output than the source.
        # VBR with `-b:v` = source bitrate produces output that's
        # perceptually indistinguishable from the original. The old
        # pre-port h264_videotoolbox transcoder on Mac did exactly this,
        # which is why "old Caramba on a 10-year-old Mac" looks better
        # than ICQ-mode QSV. Upstream Jellyfin's GetVideoBitrateParam
        # (cs:1609-1644) takes the same approach for QSV.
        #
        # The target bitrate comes from `Bitrate.video_bitrate_for(job)`
        # — which `TranscodeManager#resolve_video_bitrate` clamps to the
        # source's actual bitrate. So a 12 Mbps BluRay rip stays at
        # 12 Mbps; a 2 Mbps webrip stays at 2 Mbps; client max_bitrate
        # caps the top end.
        #
        # `-preset veryfast` — upstream's QSV default (cs:1761). On the
        # HW encoder, preset is a speed/CPU trade-off; visual quality
        # is dominated by the rate-control settings above. Slower
        # presets (`medium`/`slow`) take 30-60 s to flush the first
        # HLS segment on a 4K source; `veryfast` brings that to
        # ~2-3 s — the right call for HLS where first-segment latency
        # is the user-perceived "time to play".
        #
        # `-mbbrc 1` — MacroBlock-level bitrate control (upstream
        # cs:1621). Inside the target bitrate envelope, allocates more
        # bits to busy regions of each frame. Visibly cleaner edges
        # and motion at the same average bitrate.
        #
        # `-rc_init_occupancy` and `-bufsize` follow upstream's
        # heuristic: `init_occupancy = bitrate * factor` (factor=2 for
        # Level 5+ profiles, 1 otherwise), `bufsize = 2 * init_occupancy`.
        # Factor 2 gives headroom for I-frame spikes; 1 keeps strict CPB
        # for lower-level decoders.
        #
        # NOT emitted on purpose (vs. earlier draft):
        #
        # `-global_quality` — replaced by `-b:v` (see above). Mixing
        # both confuses h264_qsv's rate-control selection.
        #
        # `-low_power 1` — upstream gates this behind
        # EnableIntelLowPowerH264HwEncoder (default OFF). VDEnc is
        # faster but visibly LOWER quality at the same bitrate, AND
        # runs on an engine standard GPU monitors don't surface ("13%
        # GPU but picture is trash" was the symptom).
        #
        # `-look_ahead 0`, `-async_depth N` — ffmpeg already picks
        # sane defaults; no need to override.
        def encoder_args(job)
          bitrate = Bitrate.video_bitrate_for(job)
          factor  = high_level_profile?(job) ? 2 : 1
          init_occ = bitrate * factor
          bufsize  = init_occ * 2

          args = [ '-preset', 'veryfast', '-mbbrc', '1' ]
          args.concat([
            '-b:v',                bitrate.to_s,
            '-maxrate',            (bitrate + 1).to_s,
            '-rc_init_occupancy',  init_occ.to_s,
            '-bufsize',            bufsize.to_s
          ])
          args
        end

        # Larger CPB window for high-Level profiles (5.0+). Mirrors
        # upstream's heuristic at cs:1626-1634.
        def high_level_profile?(job)
          level = job.options.respond_to?(:video_level) ? job.options.video_level : nil
          return true if level.nil?
          level.to_f >= 5.0
        end

        # CRF-equivalent value for the configured target codec. Reads the
        # same EncodingOptions field the SW `rate_control_args` uses for
        # libx264 / libx265 so QSV quality stays in lockstep with the SW
        # path — switching `CARAMBA_HWACCEL` from qsv to none shouldn't
        # change the perceived quality.
        def quality_for(job)
          case job.output_video_codec.to_s.downcase
          when 'h265', 'hevc' then job.options.h265_crf
          when 'av1'          then job.options.av1_crf
          else                     job.options.h264_crf
          end
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
        #
        # IMPORTANT: width/height must be concrete integers. vpp_qsv's
        # argument parser doesn't evaluate ffmpeg's expression DSL
        # (`-2`, `min(…,ih)`) the way the generic `scale` filter does —
        # passing them silently stalls the filter graph (no error, no
        # frames produced, init-segment requests loop on 504s). Upstream
        # `GetHwScaleFilter` (EncodingHelper.cs:3255) always computes
        # concrete integers via `GetFixedOutputSize`; we mirror that
        # here. Symptom seen: Iron Giant (1080p → 1080p, scale was a
        # no-op) worked, Aladdin (4K → 1080p, scale actually invoked)
        # silently stalled.
        #
        # HDR sources also need `:tonemap=1` (upstream cs:4537) so iHD's
        # VPL runtime converts HDR-PQ → SDR-Rec.709 in the same pass —
        # without it, h264_qsv (8-bit, no HDR support) silently stalls.
        def hw_decode_chain(job)
          parts = [ 'vpp_qsv' ]
          out_w, out_h = fixed_output_size(job)
          dims_set = out_w && out_h
          format_set = true  # always force format=nv12 for the h264_qsv encoder

          arg_pairs = []
          arg_pairs << "w=#{out_w}" << "h=#{out_h}" if dims_set
          arg_pairs << 'format=nv12' if format_set
          arg_pairs << 'tonemap=1' if job.hdr_input?

          dims_set ? "vpp_qsv=#{arg_pairs.join(':')}" : "vpp_qsv=#{arg_pairs.join(':')}"
        end

        # SW-decode branch (mirrors EncodingHelper.cs:4730-4757). Input is
        # CPU memory (yuv420p / yuv420p10le); we scale + format-convert in
        # software and hand CPU NV12 to h264_qsv, which uploads internally
        # — no explicit hwupload needed.
        #
        # HDR sources get an extra `zscale,tonemap` leg before format=nv12
        # so the HDR-PQ pixels are converted to SDR-Rec.709 in software.
        # Mirrors upstream EncodingHelper's swTonemap path.
        def sw_decode_chain(job)
          parts = []
          if job.hdr_input?
            parts << 'zscale=t=linear:npl=100'
            parts << 'format=gbrpf32le'
            parts << 'zscale=p=bt709'
            parts << "tonemap=hable:desat=0:peak=#{tonemap_peak(job)}"
            parts << 'zscale=t=bt709:m=bt709:r=tv'
          end
          out_w, out_h = fixed_output_size(job)
          parts << "scale=#{out_w}:#{out_h}:flags=lanczos" if out_w && out_h
          parts << 'format=nv12'
          parts.join(',')
        end

        # Compute concrete output dimensions for the scaler. Returns
        # [width, height] or [nil, nil] when no resize is needed (source
        # already at or below the requested height). Mirrors upstream
        # `GetFixedOutputSize` — preserves aspect ratio, even integers.
        def fixed_output_size(job)
          return [ nil, nil ] unless job.output_height
          src_w = job.video_stream&.width
          src_h = job.video_stream&.height
          return [ nil, nil ] unless src_w && src_h && src_h.positive?
          # Never upscale.
          return [ nil, nil ] if src_h <= job.output_height
          target_h = job.output_height
          ratio = target_h.to_f / src_h
          target_w = (src_w * ratio).round
          target_w -= 1 if target_w.odd?
          target_h -= 1 if target_h.odd?
          [ target_w, target_h ]
        end

        def tonemap_peak(job)
          peak = job.options&.tonemapping_peak if job.options.respond_to?(:tonemapping_peak)
          peak.is_a?(Numeric) && peak.positive? ? peak : 100
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
