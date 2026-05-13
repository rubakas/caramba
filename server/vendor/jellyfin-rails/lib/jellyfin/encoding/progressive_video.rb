module Jellyfin
  module Encoding
    # Port of EncodingHelper.GetProgressiveVideoFullCommandLine (cs:7573) +
    # GetProgressiveVideoArguments (cs:7624) + GetProgressiveVideoAudioArguments.
    #
    # Builds the ffmpeg arg list for a SINGLE-FILE video transcode (mp4 / mkv /
    # webm / ts) — the `/Videos/{id}/stream.{container}` endpoint. Distinct
    # from the HLS pipeline in three ways:
    #
    #   - one output file, not many segments
    #   - `-codec:v:0` / `-codec:a:0` instead of `-c:v` / `-c:a` (positional
    #     stream specifiers; upstream uses these for the explicit -map order)
    #   - mp4 muxer flags: `frag_keyframe+empty_moov+delay_moov` so the player
    #     can start before the whole file arrives (the upstream comment cites
    #     issue #9248)
    module ProgressiveVideo
      module_function

      # Returns the args array for the progressive transcode. `output_path` is
      # a local file or 'pipe:1' for streaming.
      def command_line(job:, output_path:, capabilities:)
        helper  = Jellyfin::Encoding::EncodingHelper.new(capabilities)
        backend = helper.send(:resolve_hwaccel, job)
        plan    = Jellyfin::Encoding::Seek.plan_for(job)
        input_args_list, _cleanup = Jellyfin::Encoding::InputSource.build(job)

        args  = []
        args += helper.send(:global_args)
        args += helper.send(:probe_args, job)
        args += helper.send(:dovi_input_args, job)
        args += backend ? backend.decode_args(job, capabilities) : []
        args += plan.pre_input
        args += input_args_list
        args += plan.post_input
        args += map_args(job)
        args += video_args(job, capabilities, backend: backend, helper: helper)
        args += audio_args(job, capabilities, helper: helper)
        args += subtitle_embed_args(job)
        args += movflag_args(output_path)
        args += ['-map_metadata', '-1', '-map_chapters', '-1', '-y', output_path]
        args
      end

      # Mirrors GetMapArgs as used from the progressive path. Always emits
      # explicit -map for the chosen video + audio streams.
      def map_args(job)
        out = ['-map', "0:v:#{stream_index(job.media_source.video_streams, job.video_stream)}"]
        out += ['-map', "0:a:#{stream_index(job.media_source.audio_streams, job.audio_stream)}?"] if job.audio_stream
        out
      end

      # Mirrors GetProgressiveVideoArguments (cs:7624). The key difference
      # vs HLS: positional `-codec:v:0` and a video-only `-codec:v:0 copy`
      # short-circuit when no re-encode is needed.
      def video_args(job, caps, backend:, helper:)
        encoder = backend&.encoder_for(job.output_video_codec, caps) ||
                  Jellyfin::Encoding::CodecSelector.video_encoder_for(job.output_video_codec, caps)
        return ['-codec:v:0', 'copy'] if encoder == 'copy' || job.stream_copy_video?

        out  = ['-codec:v:0', encoder]
        out += backend ? backend.encoder_args(job) : helper.send(:quality_args, job, encoder)
        out += helper.send(:rate_control_args, job)
        out += helper.send(:pixel_format_args, job)
        out += helper.send(:keyframe_args, job)
        out += helper.send(:hdr_passthrough_args, job)

        chain = backend&.filter_chain(job, caps) || helper.send(:filter_chain, job)
        out += ['-vf', chain] unless chain.nil? || chain.empty?
        out
      end

      # Audio leg of the progressive pipeline. Mirrors
      # GetProgressiveVideoAudioArguments — uses positional `-codec:a:0`.
      def audio_args(job, caps, helper:)
        encoder = Jellyfin::Encoding::CodecSelector.audio_encoder_for(job.output_audio_codec, caps)
        return ['-codec:a:0', 'copy'] if encoder == 'copy' || job.stream_copy_audio?

        b  = Jellyfin::Encoding::Bitrate.audio_bitrate_for(job)
        ch = Jellyfin::Encoding::Bitrate.audio_channels_for(job)
        ['-codec:a:0', encoder, '-b:a', b.to_s, '-ac', ch.to_s,
         '-ar', job.output_audio_sample_rate.to_s]
      end

      # Mirrors GetSubtitleEmbedArguments for the progressive path. We only
      # support the mov_text family — burning into the video is handled by
      # the regular -vf chain.
      def subtitle_embed_args(job)
        return [] unless job.subtitle_stream
        return [] unless job.subtitle_method == :embedded
        ['-codec:s:0', 'mov_text']
      end

      # MP4 streaming requires fragment flags so the moov atom doesn't pin
      # delivery until the entire file is encoded. Upstream cs:7586.
      def movflag_args(output_path)
        return [] unless output_path.to_s.match?(/\.mp4\z/i) || output_path == 'pipe:1'
        ['-f', 'mp4', '-movflags', 'frag_keyframe+empty_moov+delay_moov']
      end

      def stream_index(list, target)
        return 0 unless target
        list.index { |s| s.index == target.index } || 0
      end
    end
  end
end
