module Jellyfin
  module Encoding
    # Port of EncodingHelper.NormalizeTranscodingLevel (cs:1821). Validates a
    # requested level number against the maximum the codec spec / Jellyfin
    # decides is "safe for maximum compatibility".
    #
    # Upstream gates (for reference):
    #   AV1   — level ≤ 15 (5.3)         else clamp to 15
    #   HEVC  — level ≤ 150              else clamp to 150 (= 5.0)
    #   H.264 — level ≤ 51               else clamp to 51 (= 5.1)
    #
    # The numeric form upstream uses is profile_idc-scaled (level × 30 for
    # HEVC, level × 10 for H.264, integer for AV1). We accept either the
    # scaled int form (e.g., 41 for H.264 level 4.1) or the dotted form
    # ("4.1") and return whichever the caller passed in.
    module LevelNormalizer
      module_function

      def normalize(video_codec:, level:)
        return nil if level.nil?
        request_level = parse_level(level)
        return nil if request_level.nil?

        cap =
          case video_codec.to_s.downcase
          when 'av1'                   then 15
          when 'hevc', 'h265'          then 150
          when 'h264'                  then 51
          end
        return level.to_s if cap.nil? # unknown codec — passthrough

        return cap.to_s if request_level.negative? || request_level >= cap
        level.to_s
      end

      def parse_level(level)
        s = level.to_s
        return Float(s) if s.include?('.') # dotted form like "4.1"
        Integer(s) rescue Float(s) rescue nil
      end
    end
  end
end
