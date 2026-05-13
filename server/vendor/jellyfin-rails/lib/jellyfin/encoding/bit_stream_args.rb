module Jellyfin
  module Encoding
    # Port of EncodingHelper.GetBitStreamArgs(state, MediaStreamType) (cs:1481)
    # and GetAudioBitStreamArguments (cs:1551). These are the canonical
    # upstream method signatures for per-stream-type bitstream filter
    # selection. Distinct from our existing `BitstreamFilters.for(target_container:)`
    # which is keyed on output container; this module is keyed on stream type
    # + dynamic HDR removal plan.
    module BitStreamArgs
      module_function

      # Port of GetBitStreamArgs (cs:1481). `stream_type` is :video or :audio.
      def call(job:, stream_type: :video)
        stream =
          case stream_type
          when :audio then job.audio_stream
          else             job.video_stream
          end
        return nil unless stream

        case stream.codec.to_s.downcase
        when 'h264', 'avc'
          ['-bsf:v', 'h264_mp4toannexb']
        when 'aac'
          # ADTS (mpegts) → ASC (mp4) header conversion.
          ['-bsf:a', 'aac_adtstoasc']
        when 'h265', 'hevc'
          h265_args(job)
        when 'av1'
          av1_args(job)
        end
      end

      # Port of GetAudioBitStreamArguments (cs:1551). Only emits the audio
      # bitstream filter when the segment container is mp4-family AND the
      # source container is mpegts-derived (ts / aac / hls).
      def audio_call(job:, segment_container:, media_source_container:)
        seg = segment_container.to_s.downcase
        src = media_source_container.to_s.downcase
        return [] unless seg == 'mp4' && %w[ts aac hls].include?(src)
        call(job: job, stream_type: :audio) || []
      end

      def h265_args(job)
        args = ['-bsf:v', 'hevc_mp4toannexb']
        return args unless Jellyfin::Encoding::DynamicHdrStatus.dovi_removed?(job) ||
                           Jellyfin::Encoding::DynamicHdrStatus.hdr10plus_removed?(job)
        # Upstream concatenates the metadata-removal filter onto the same
        # `-bsf:v` value with a comma separator (cs:1519).
        if Jellyfin::Encoding::DynamicHdrStatus.dovi_removed?(job)
          args[-1] = 'hevc_mp4toannexb,hevc_metadata=remove_dovi=1'
        elsif Jellyfin::Encoding::DynamicHdrStatus.hdr10plus_removed?(job)
          args[-1] = 'hevc_mp4toannexb,hevc_metadata=remove_hdr10plus=1'
        end
        args
      end

      def av1_args(job)
        if Jellyfin::Encoding::DynamicHdrStatus.dovi_removed?(job)
          ['-bsf:v', 'av1_metadata=remove_dovi=1']
        elsif Jellyfin::Encoding::DynamicHdrStatus.hdr10plus_removed?(job)
          ['-bsf:v', 'av1_metadata=remove_hdr10plus=1']
        end
      end
    end
  end
end
