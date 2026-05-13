module Jellyfin
  module Encoding
    # Port of EncodingHelper.TryStreamCopy (cs:7144). Mutates the job in
    # place to enable `copy` for video and/or audio whenever the source is
    # eligible. Mirrors upstream exactly:
    #
    #   - If `StreamCopy.video?` says yes, set `output_video_codec = 'copy'`
    #   - If `StreamCopy.audio?` says yes (and HLS audio-seek doesn't force
    #     transcode), set `output_audio_codec = 'copy'`
    #
    # The user-permission gate from upstream (the
    # `EnableVideoPlaybackTranscoding` permission flag that FORCES copy when
    # transcoding is disabled even for incompatible sources) doesn't apply
    # here because we don't model users. Production deployments wanting that
    # behaviour can pass `force_copy: true` to override.
    module TryStreamCopy
      module_function

      def call(job, profile: nil, force_copy: false)
        if force_copy || stream_copy_video?(job, profile)
          job.output_video_codec = 'copy'
        end
        if force_copy || stream_copy_audio?(job, profile)
          job.output_audio_codec = 'copy'
        end
        job
      end

      def stream_copy_video?(job, profile)
        return false unless job.video_stream
        result = Jellyfin::Encoding::StreamCopy.video?(job, profile: profile)
        result.eligible?
      end

      def stream_copy_audio?(job, profile)
        return false unless job.audio_stream
        result = Jellyfin::Encoding::StreamCopy.audio?(job, profile: profile)
        result.eligible?
      end
    end
  end
end
