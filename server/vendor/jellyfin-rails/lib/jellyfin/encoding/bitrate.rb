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

      module_function

      # Returns the effective video bitrate in bits/sec for the chosen output codec.
      def video_bitrate_for(job)
        base = job.output_video_bitrate
        scale = CODEC_SCALE.fetch(job.output_video_codec.to_s.downcase, 1.0)
        (base * scale).to_i
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
