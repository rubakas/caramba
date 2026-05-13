module Jellyfin
  module Output
    # RFC 6381 codec strings used in HLS/DASH manifests. Browsers / TVs use
    # these to decide whether they can play a variant *before* downloading any
    # segment. Mirrors EncodingHelper.cs GetCodecString and the Jellyfin Web
    # client's `parseCodecs` heuristic.
    module CodecString
      module_function

      # Returns a comma-joined RFC 6381 codecs string (`avc1.640028,mp4a.40.2`).
      def for(video_codec:, audio_codec:, profile: nil, level: nil, audio_channels: 2)
        [video_string(video_codec, profile: profile, level: level),
         audio_string(audio_codec, channels: audio_channels)].compact.join(',')
      end

      def video_string(codec, profile: nil, level: nil)
        case codec.to_s.downcase
        when 'h264', 'avc', 'libx264'
          # avc1.PPCCLL  PP = profile_idc, CC = constraints, LL = level_idc
          profile_idc = h264_profile_idc(profile)
          level_idc   = (level.to_f * 10).to_i.to_s(16).rjust(2, '0')
          "avc1.#{profile_idc}00#{level_idc}"
        when 'h265', 'hevc', 'libx265'
          # hev1.1.6.L120.B0  — simplified; main / main10 / main12 differ in profile_space
          main = profile.to_s.downcase
          tier = 'L'
          level_part = level ? "#{tier}#{(level.to_f * 30).to_i}" : 'L120'
          case main
          when 'main10' then "hev1.2.4.#{level_part}.B0"
          when 'main12' then "hev1.3.4.#{level_part}.B0"
          else "hev1.1.6.#{level_part}.B0"
          end
        when 'av1', 'av01', 'libsvtav1', 'libaom-av1'
          # av01.P.LLT.BB  — main profile, level 8 (4K), bitdepth 8
          'av01.0.08M.08'
        when 'vp9', 'libvpx-vp9'
          'vp09.00.10.08'
        end
      end

      def audio_string(codec, channels: 2)
        case codec.to_s.downcase
        when 'aac', 'libfdk_aac' then 'mp4a.40.2'  # AAC-LC
        when 'he-aac', 'aac_he'  then 'mp4a.40.5'
        when 'mp3', 'libmp3lame' then 'mp4a.69'
        when 'ac3'               then 'ac-3'
        when 'eac3'              then 'ec-3'
        when 'opus', 'libopus'   then 'opus'
        when 'flac'              then 'flac'
        end
      end

      def h264_profile_idc(profile)
        case profile.to_s.downcase
        when 'baseline'     then '42'
        when 'main'         then '4D'
        when 'high'         then '64'
        when 'high10'       then '6E'
        when 'high422'      then '7A'
        when 'high444'      then 'F4'
        else '64' # default to High when unknown
        end
      end
    end
  end
end
