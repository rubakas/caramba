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
          # `hvc1.*` not `hev1.*` — Apple's HLS Authoring Spec
          # ("Validating HLS Streams", section "Codecs Attributes for
          # HEVC") REQUIRES `hvc1.*` in the master playlist's CODECS
          # attribute when the fMP4 sample entry uses the `hvc1` tag.
          # ffmpeg's HLS muxer is configured with `-tag:v hvc1` for
          # HEVC stream-copy (encoding_helper#hls_output_args), so the
          # sample entry IS `hvc1` and the CODECS attribute must match.
          # Mismatch (`hev1` advertised, `hvc1` on the wire) makes
          # Safari reject the master playlist with MEDIA_ERR_DECODE
          # before fetching any segment.
          #
          # Profile matching is whitespace-insensitive: ffprobe reports
          # HEVC Main 10 with a SPACE (`Main 10`) while RFC 6381's
          # codec-string token has no space (`main10`). Upstream
          # Jellyfin matches both forms — HlsCodecStringHelpers.cs:213
          # — and we have to too: otherwise a `Main 10` source falls
          # through to the `else` branch and we advertise as Main
          # (`hvc1.1.6.*`) while the bitstream is Main 10
          # (`hvc1.2.4.*`). Safari spots the CODECS-vs-bitstream
          # mismatch and surfaces MEDIA_ERR_DECODE before any segment
          # is fetched (the user's `Office S01E03` reproduces this).
          main = profile.to_s.downcase.delete(' ')
          # HEVC codec-string level is the level_idc value itself
          # (`L120` = level_idc 120 = HEVC Level 4.0). Callers must pass
          # the level_idc directly — we DO NOT scale it. Mirrors upstream
          # HlsCodecStringHelpers.cs:223-225 which appends `level` raw.
          # The previous `level * 30` formula was inherited from a wrong
          # generalisation of the H.264 `* 10` convention; for HEVC it
          # produced impossible levels (e.g. L360 for source level 120)
          # which Safari rejected with MEDIA_ERR_DECODE.
          level_part = level ? "L#{level.to_i}" : 'L120'
          case main
          when 'main10' then "hvc1.2.4.#{level_part}.B0"
          when 'main12' then "hvc1.3.4.#{level_part}.B0"
          else "hvc1.1.6.#{level_part}.B0"
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
