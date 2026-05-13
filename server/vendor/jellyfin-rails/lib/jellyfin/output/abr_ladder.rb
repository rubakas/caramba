module Jellyfin
  module Output
    # ABR ladder math. Given a source resolution + bitrate, produce a ladder of
    # variants for adaptive streaming. The numbers mirror the Apple "HLS
    # Authoring Specification" recommended ladder for an H.264 baseline.
    #
    # The ladder is filtered to only include variants ≤ the source resolution
    # (don't upscale — wastes encoder time and looks worse).
    module AbrLadder
      Variant = Struct.new(:name, :height, :width, :video_bitrate, :audio_bitrate, keyword_init: true)

      DEFAULT_LADDER = [
        { name: '240p',  height: 240,  width: 426,  video_bitrate: 400_000,   audio_bitrate: 64_000  },
        { name: '360p',  height: 360,  width: 640,  video_bitrate: 800_000,   audio_bitrate: 96_000  },
        { name: '480p',  height: 480,  width: 854,  video_bitrate: 1_400_000, audio_bitrate: 128_000 },
        { name: '720p',  height: 720,  width: 1280, video_bitrate: 2_800_000, audio_bitrate: 128_000 },
        { name: '1080p', height: 1080, width: 1920, video_bitrate: 5_000_000, audio_bitrate: 192_000 },
        { name: '1440p', height: 1440, width: 2560, video_bitrate: 9_000_000, audio_bitrate: 192_000 },
        { name: '4K',    height: 2160, width: 3840, video_bitrate: 18_000_000, audio_bitrate: 256_000 }
      ].freeze

      module_function

      # Returns variants ≤ the source resolution. Caller may pass a cap to
      # honor a client-side max (e.g., a mobile profile capping at 720p).
      # `max_bitrate` mirrors upstream Jellyfin's `MediaInfoHelper.GetMaxBitrate`
      # — it's the client-reported MaxStreamingBitrate, post-applied to the
      # ladder so we never emit a rung the client can't fetch.
      def build(source_height:, source_bitrate: nil, max_height: nil, max_bitrate: nil, ladder: DEFAULT_LADDER)
        cap = [source_height || Float::INFINITY, max_height || Float::INFINITY].min

        chosen = ladder.select { |v| v[:height] <= cap }
        # If the source is between rungs (e.g., 900p), make sure we don't emit
        # a higher-than-source ladder rung. The .select above does that. But we
        # also clamp the *bitrate* — don't burn 5Mbps re-encoding a 2Mbps source.
        chosen = chosen.map do |v|
          out = v.dup
          out[:video_bitrate] = [v[:video_bitrate], source_bitrate || v[:video_bitrate]].min
          Variant.new(**out)
        end

        # MaxStreamingBitrate filtering — drop rungs whose total (v+a) bitrate
        # exceeds what the client says it can handle. Mirrors upstream's
        # SetDeviceSpecificData → ResolveBitrate path which applies the cap
        # before returning the playable source list.
        if max_bitrate
          chosen = chosen.select { |v| (v.video_bitrate + v.audio_bitrate) <= max_bitrate.to_i }
        end

        # Ensure at least one rung is emitted even for low-res sources.
        chosen.empty? ? [Variant.new(**ladder.first)] : chosen
      end
    end
  end
end
