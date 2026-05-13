module Jellyfin
  module Encoding
    # ffmpeg bitstream filters (`-bsf:v`/`-bsf:a`). These are NAL-level fixups
    # required when a stream-copy crosses certain container boundaries.
    #
    # The mappings here mirror what EncodingHelper.cs emits in its
    # `GetVideoBitstreamArgs` / `GetAudioBitstreamArgs` paths.
    #
    # Common cases:
    #
    #   h264_mp4toannexb  — MP4 stores h264 with length-prefixed NALs; MPEG-TS
    #                       expects start-code-prefixed NALs (Annex B). Without
    #                       this filter the first .ts segment is unplayable.
    #   hevc_mp4toannexb  — same idea for h265.
    #   aac_adtstoasc     — AAC in MPEG-TS has ADTS headers; MP4 expects raw
    #                       ASC. Skip this and the .mp4 player gets framing
    #                       errors.
    #   dump_extra        — forces ffmpeg to include the SPS/PPS in each .ts
    #                       segment so a client tuning in mid-stream can decode.
    module BitstreamFilters
      module_function

      # Returns the bitstream-filter args needed for a (source-container,
      # target-container, codec) combo. Always emits a minimum set; callers
      # don't have to think about it.
      def for(target_container:, video_codec: 'h264', audio_codec: 'aac', source_is_avc: nil)
        args = []
        args.concat(video_filter(target_container, video_codec, source_is_avc))
        args.concat(audio_filter(target_container, audio_codec))
        args
      end

      def video_filter(target, codec, source_is_avc)
        codec = codec.to_s.downcase
        case target.to_s.downcase
        when 'hls', 'ts', 'mpegts'
          # MP4-style avcC bitstreams must become Annex B before TS muxing.
          # `source_is_avc=false` would mean the source is already Annex B —
          # rare but worth honoring.
          return [] if source_is_avc == false
          case codec
          when 'h264', 'libx264' then ['-bsf:v', 'h264_mp4toannexb']
          when 'hevc', 'h265', 'libx265' then ['-bsf:v', 'hevc_mp4toannexb']
          else []
          end
        when 'mp4', 'mkv'
          # MP4 / Matroska accept either format, but adding `dump_extra` makes
          # mid-stream tune-in safer.
          ['-bsf:v', 'dump_extra']
        else
          []
        end
      end

      def audio_filter(target, codec)
        codec = codec.to_s.downcase
        case target.to_s.downcase
        when 'mp4', 'mkv'
          # AAC-in-TS uses ADTS framing; MP4 wants AudioSpecificConfig only.
          case codec
          when 'aac', 'libfdk_aac' then ['-bsf:a', 'aac_adtstoasc']
          else []
          end
        else
          []
        end
      end
    end
  end
end
