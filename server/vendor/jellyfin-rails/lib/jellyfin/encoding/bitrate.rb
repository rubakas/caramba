module Jellyfin
  module Encoding
    # Ports GetVideoBitrateParamValue and related bitrate helpers from EncodingHelper.cs.
    #
    # Upstream applies codec-specific scaling factors: h265 needs ~60% of h264's
    # bitrate for similar quality, av1 needs ~50%. We mirror those constants.
    module Bitrate
      CODEC_SCALE = {
        'h264'      => 1.0,
        'libx264'   => 1.0,
        'h265'      => 0.6,
        'hevc'      => 0.6,
        'libx265'   => 0.6,
        'av1'       => 0.5,
        'libsvtav1' => 0.5,
        'libaom-av1' => 0.5
      }.freeze

      # Per-target-width bitrate ceilings (bits/sec) for the H.264 baseline.
      # Mirrors the pre-jellyfin-rails Caramba transcoder's
      # `video_bitrate_cap_bps` (server/app/services/transcoder_service.rb)
      # which existed precisely so that a 60-80 Mbps 4K HEVC source rip
      # would not flow through unchanged into a 1080p H.264 transcode —
      # the encoder would dutifully produce 60 Mbps 1080p H.264 (visually
      # indistinguishable from ~20 Mbps at 1080p) and the resulting HLS
      # segments would be 4× larger than needed, slowing every fetch and
      # producing huge "first segment after seek" responses.
      RESOLUTION_BITRATE_CAP_BPS = [
        [ 3000, 40_000_000 ], # 4K and up (cap 40 Mbps)
        [ 1800, 20_000_000 ], # 1080p (cap 20 Mbps)
        [ 1100, 12_000_000 ], # 720p  (cap 12 Mbps)
        [    0,  6_000_000 ]  # below 720p (cap 6 Mbps)
      ].freeze

      module_function

      # Returns the effective video bitrate in bits/sec for the chosen output codec.
      def video_bitrate_for(job)
        base  = job.output_video_bitrate
        scale = CODEC_SCALE.fetch(job.output_video_codec.to_s.downcase, 1.0)
        cap   = resolution_bitrate_cap(job)
        [ (base * scale).to_i, (cap * scale).to_i ].min
      end

      # Caps target output bitrate by output (or source) width. For codecs
      # with better compression than H.264 (HEVC/AV1), the same scale
      # factor used elsewhere applies — HEVC at 1080p needs ~12 Mbps for
      # the same quality H.264 hits at 20 Mbps, so HEVC@1080p ≈ 12 Mbps.
      def resolution_bitrate_cap(job)
        target_w = target_width_for(job)
        return 40_000_000 if target_w.nil? || target_w.zero?
        entry = RESOLUTION_BITRATE_CAP_BPS.find { |min_w, _cap| target_w >= min_w }
        entry ? entry[1] : 6_000_000
      end

      # Resolve the target output width. Honour explicit overrides first;
      # otherwise compute from output_height + source aspect; otherwise
      # fall back to source width (no downscale planned).
      def target_width_for(job)
        return job.output_width if job.output_width
        src_w = job.video_stream&.width
        src_h = job.video_stream&.height
        return src_w unless job.output_height && src_w && src_h && src_h.positive?
        # Aspect-preserving downscale.
        target_h = [ job.output_height, src_h ].min
        ((src_w * (target_h.to_f / src_h)).round) | 0
      end

      def audio_bitrate_for(job)
        # Per-channel scaled target. Bitrate per channel mirrors Jellyfin's
        # audio profile defaults; capped by the source rate (we never inflate)
        # and by the user-set `output_audio_bitrate`.
        channels = audio_channels_for(job)
        codec_target = Audio.bitrate_for(
          codec: job.output_audio_codec,
          channels: channels,
          base: job.output_audio_bitrate
        )
        target = [job.output_audio_bitrate, codec_target].min
        return target unless job.audio_stream&.bit_rate
        [target, job.audio_stream.bit_rate].min
      end

      # Number of output audio channels. Upstream downmixes 5.1→2.0 by default
      # when the target client can't handle multichannel; we expose the policy.
      def audio_channels_for(job)
        return job.output_audio_channels if job.output_audio_channels
        return job.audio_stream.channels if job.audio_stream&.channels && job.audio_stream.channels <= 2
        2
      end
    end
  end
end
