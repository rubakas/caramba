module Jellyfin
  module Encoding
    # Ports of static helpers from EncodingHelper.cs that infer codec/format
    # names from container or URL extension. Used by the request → state
    # mapper to fill in defaults when the client doesn't supply one.
    module CodecInference
      # Port of EncodingHelper.cs:90 — `_videoProfilesH264` array (canonical
      # ordering used by GetVideoProfileScore as a compatibility rank).
      VIDEO_PROFILES_H264 = %w[
        ConstrainedBaseline Baseline Extended Main High
        ProgressiveHigh ConstrainedHigh High10
      ].freeze

      # Port of EncodingHelper.cs:102 — `_videoProfilesH265`.
      VIDEO_PROFILES_H265 = %w[Main Main10].freeze

      # Port of EncodingHelper.cs:108 — `_videoProfilesAv1`.
      VIDEO_PROFILES_AV1 = %w[Main High Professional].freeze

      # Containers ffmpeg can't read directly via `-f`. Ported from
      # EncodingHelper.cs:537 GetInputFormat which returns null for these.
      UNRECOGNIZED_CONTAINERS = %w[
        m2ts wmv mts vob mpg mpeg rec dvr-ms ogm divx tp rmvb rtp m4v strm iso
      ].freeze

      module_function

      # Port of EncodingHelper.GetInputFormat (cs:537). Returns the ffmpeg
      # `-f` format string for a given container, or nil when ffmpeg should
      # auto-detect (the upstream convention for messy containers).
      def get_input_format(container)
        return nil if container.nil? || container.empty?
        return nil unless container.match?(/\A[a-zA-Z0-9_\-]+\z/) # ContainerValidationRegex

        normalized = container.downcase.sub('mkv', 'matroska')
        return 'mpegts' if normalized == 'ts'
        return nil if UNRECOGNIZED_CONTAINERS.include?(normalized)
        normalized
      end

      # Port of EncodingHelper.InferAudioCodec (cs:674). Guesses an output
      # audio codec from a container hint. Matches the upstream `switch`
      # expression on container extension.
      def infer_audio_codec(container)
        return 'aac' if container.nil? || container.to_s.strip.empty?
        c = container.to_s.downcase
        case c
        when 'ogg', 'oga', 'ogv', 'webm', 'webma' then 'opus'
        when 'm4a', 'm4b', 'mp4', 'mov', 'mkv', 'mka' then 'aac'
        when 'ts', 'avi', 'flv', 'f4v', 'swf' then 'mp3'
        else c
        end
      end

      # Port of EncodingHelper.InferVideoCodec (cs:698). Guesses video codec
      # from a URL's file extension.
      def infer_video_codec(url)
        ext = File.extname(url.to_s).downcase
        case ext
        when '.asf'             then 'wmv'
        when '.webm'            then 'vp8' # upstream TODO: may not always mean VP8
        when '.ogg', '.ogv'     then 'theora'
        when '.m3u8', '.ts'     then 'h264'
        else 'copy'
        end
      end

      # Port of EncodingHelper.GetVideoProfileScore (cs:726). Returns the
      # array index of the profile in the canonical list — higher = stronger
      # compatibility constraint. -1 means unknown profile (or unsupported codec).
      def get_video_profile_score(video_codec, video_profile)
        return -1 if video_profile.nil?
        profile = video_profile.to_s.delete(' ')
        list =
          case video_codec.to_s.downcase
          when 'h264' then VIDEO_PROFILES_H264
          when 'hevc' then VIDEO_PROFILES_H265
          when 'av1'  then VIDEO_PROFILES_AV1
          end
        return -1 unless list
        list.index { |p| p.casecmp(profile).zero? } || -1
      end
    end
  end
end
