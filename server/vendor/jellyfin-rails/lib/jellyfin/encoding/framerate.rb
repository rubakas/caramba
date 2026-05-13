module Jellyfin
  module Encoding
    # Framerate normalization and clamping. Ports the heuristics from
    # EncodingHelper.GetFramerateParam — picks the closest standard rate to
    # avoid emitting weird values that confuse downstream parsers.
    module Framerate
      # Standard cinema / broadcast rates that decoders handle smoothly.
      STANDARD = [
        24000.0 / 1001.0,  # 23.976 — film telecined to NTSC
        24.0,              # film
        25.0,              # PAL
        30000.0 / 1001.0,  # 29.97 — NTSC
        30.0,
        50.0,              # PAL HFR
        60000.0 / 1001.0,  # 59.94 — NTSC HFR
        60.0
      ].freeze

      module_function

      # Returns the closest standard rate to the input. Within 0.5 fps,
      # snap to standard; otherwise round to two decimal places.
      def normalize(rate)
        return nil if rate.nil? || rate <= 0
        nearest = STANDARD.min_by { |s| (s - rate).abs }
        (nearest - rate).abs <= 0.5 ? nearest : rate.round(3)
      end

      # Clamps a source rate down to max while preferring a standard target rate.
      # Mirrors the upstream "halve if >max" rule used for content captured at
      # 60fps but targeted to 30fps clients.
      def clamp(rate, max:)
        return nil if rate.nil?
        return rate if max.nil? || rate <= max
        # Try halving — preserves cadence for 60→30, 50→25, 59.94→29.97.
        half = rate / 2.0
        return normalize(half) if half <= max
        normalize(max.to_f)
      end

      def ffmpeg_args(target_rate)
        return [] if target_rate.nil?
        ['-r', format('%g', target_rate)]
      end
    end
  end
end
