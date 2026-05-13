module Jellyfin
  module Encoding
    # Port of EncodingHelper.GetAudioVbrModeParam (cs:2780). Returns the
    # encoder-specific VBR mode args ffmpeg expects, or nil when the encoder
    # has no VBR mode (caller falls back to `-b:a`).
    #
    # The mapping mirrors upstream exactly:
    #
    #   libfdk_aac → -vbr:a [1..5] based on per-channel bitrate
    #   libmp3lame → -qscale:a [0..6] when in the lame-VBR sweet spot,
    #                otherwise -abr:a 1 + -b:a
    #   aac_at     → -aac_at_mode:a 2 + -b:a (Apple Audio Toolbox CVBR)
    #   libvorbis  → -qscale:a [0..8] based on per-channel bitrate
    module AudioVbr
      module_function

      def args_for(encoder:, bitrate:, channels:)
        ch = [channels.to_i, 1].max
        per_channel = bitrate.to_i / ch
        case encoder.to_s.downcase
        when 'libfdk_aac' then ['-vbr:a', fdk_aac_grade(per_channel).to_s]
        when 'libmp3lame' then libmp3lame_args(per_channel, bitrate)
        when 'aac_at'     then ['-aac_at_mode:a', '2', '-b:a', bitrate.to_s]
        when 'libvorbis'  then ['-qscale:a', libvorbis_grade(per_channel).to_s]
        end
      end

      def fdk_aac_grade(per_channel)
        case per_channel
        when 0...32_000 then 1
        when 32_000...48_000 then 2
        when 48_000...64_000 then 3
        when 64_000...96_000 then 4
        else 5
        end
      end

      def libmp3lame_args(per_channel, bitrate)
        # lame's true-VBR is only good in the [48k, 122.5k] per-channel band
        # (upstream cs:2799). Outside, fall back to ABR mode + explicit -b:a.
        if per_channel > 48_000 && per_channel < 122_500
          ['-qscale:a', libmp3lame_grade(per_channel).to_s]
        else
          ['-abr:a', '1', '-b:a', bitrate.to_s]
        end
      end

      def libmp3lame_grade(per_channel)
        case per_channel
        when 0...64_000 then 6
        when 64_000...88_000 then 4
        when 88_000...112_000 then 2
        else 0
        end
      end

      def libvorbis_grade(per_channel)
        case per_channel
        when 0...40_000 then 0
        when 40_000...56_000 then 2
        when 56_000...80_000 then 4
        when 80_000...112_000 then 6
        else 8
        end
      end
    end
  end
end
