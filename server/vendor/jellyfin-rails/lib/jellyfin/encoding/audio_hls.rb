module Jellyfin
  module Encoding
    # Audio-only HLS arg builder. Port of the audio-leg of
    # `DynamicHlsController.GetMasterHlsAudioPlaylist` (cs:582) +
    # `GetVariantHlsAudioPlaylist` (cs:918) + `GetHlsAudioSegment` (cs:1273).
    #
    # The endpoints reuse the regular HLS muxer but drop the video map and
    # emit `-vn` so the resulting playlist contains only audio segments. ffmpeg
    # writes `.aac` or `.m4s` segments depending on `segment_container`.
    module AudioHls
      DEFAULT_SEGMENT_CONTAINER = 'aac'.freeze
      DEFAULT_SEGMENT_LENGTH = 6

      module_function

      # Returns the full ffmpeg arg list for an audio-only HLS transcode.
      # `output_path` is the variant playlist; `segment_template` is the
      # ffmpeg segment filename pattern (e.g., "/tmp/job/%d.aac").
      def command_line(job:, playlist_path:, segment_template:, capabilities:)
        helper = Jellyfin::Encoding::EncodingHelper.new(capabilities)
        input_args_list, _cleanup = Jellyfin::Encoding::InputSource.build(job)

        args  = []
        args += helper.send(:global_args)
        args += helper.send(:probe_args, job)
        args += input_args_list
        args += ['-vn'] # drop video
        args += map_audio(job)
        args += audio_args(job, capabilities, helper: helper)
        args += hls_output_args(job, playlist_path: playlist_path, segment_template: segment_template)
        args
      end

      def map_audio(job)
        idx = job.media_source.audio_streams.index { |s| s.index == job.audio_stream&.index } || 0
        ['-map', "0:a:#{idx}"]
      end

      def audio_args(job, caps, helper:)
        encoder = Jellyfin::Encoding::CodecSelector.audio_encoder_for(job.output_audio_codec, caps)
        return ['-c:a', 'copy'] if encoder == 'copy' || job.stream_copy_audio?

        b = Jellyfin::Encoding::Bitrate.audio_bitrate_for(job)
        ch = Jellyfin::Encoding::Bitrate.audio_channels_for(job)
        ['-c:a', encoder, '-b:a', b.to_s, '-ac', ch.to_s, '-ar', job.output_audio_sample_rate.to_s]
      end

      def hls_output_args(job, playlist_path:, segment_template:)
        container = job.options.respond_to?(:hls_audio_segment_container) ?
          job.options.hls_audio_segment_container : DEFAULT_SEGMENT_CONTAINER
        # Default playlist type follows the same live/event rule as video HLS.
        rtt = job.media_source.respond_to?(:run_time_ticks) ? job.media_source.run_time_ticks : nil
        playlist_type = (rtt.nil? || rtt.to_i.zero?) ? 'live' : 'event'

        [
          '-f', 'hls',
          '-hls_time', (job.segment_length || DEFAULT_SEGMENT_LENGTH).to_s,
          '-hls_playlist_type', playlist_type,
          '-hls_segment_type', segment_type_for(container),
          '-hls_segment_filename', segment_template,
          playlist_path
        ]
      end

      def segment_type_for(container)
        case container.to_s.downcase
        when 'm4s', 'mp4', 'fmp4' then 'fmp4'
        else                           'mpegts'
        end
      end
    end
  end
end
