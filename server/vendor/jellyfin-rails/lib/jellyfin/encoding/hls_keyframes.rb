module Jellyfin
  module Encoding
    # Port of EncodingHelper.GetHlsVideoKeyFrameArguments (cs:1956). Forces
    # ffmpeg to emit a keyframe at every segment boundary, with different
    # strategies per encoder:
    #
    #   - HW encoders that can't honour -force_key_frames → -g:v:0 N + -keyint_min:v:0 N
    #   - x264/x265/vaapi-encoders → -force_key_frames expr:gte(t,n_forced*N)
    #                                + -sc_threshold:v:0 0 for libx264
    #   - others (libvpx etc) → both keyframe args
    #
    # Plus a Q-fix for AMD HEVC VAAPI that breaks iOS fmp4 playback
    # (`-flags:v -global_header`, cs:2019).
    module HlsKeyframes
      GOP_ONLY_ENCODERS = %w[
        h264_qsv h264_nvenc h264_amf h264_rkmpp
        hevc_qsv hevc_nvenc hevc_rkmpp
        av1_qsv av1_nvenc av1_amf
        libsvtav1
      ].freeze

      KEYFRAME_EXPR_ENCODERS = %w[
        libx264 libx265 h264_vaapi hevc_vaapi av1_vaapi
      ].freeze

      module_function

      def args(job:, codec:, segment_length:, framerate: nil)
        framerate ||= job.video_stream&.frame_rate
        gop_size = framerate ? (segment_length.to_f * framerate.to_f).ceil : nil
        codec = codec.to_s.downcase
        out = []

        if GOP_ONLY_ENCODERS.include?(codec) && gop_size
          out.concat(['-g:v:0', gop_size.to_s, '-keyint_min:v:0', gop_size.to_s])
        elsif KEYFRAME_EXPR_ENCODERS.include?(codec)
          out.concat(['-force_key_frames:0', "expr:gte(t,n_forced*#{segment_length})"])
          out.concat(['-sc_threshold:v:0', '0']) if codec == 'libx264'
        else
          out.concat(['-force_key_frames:0', "expr:gte(t,n_forced*#{segment_length})"])
          out.concat(['-g:v:0', gop_size.to_s, '-keyint_min:v:0', gop_size.to_s]) if gop_size
        end

        # AMD HEVC VAAPI quirk (upstream cs:2019).
        if codec == 'hevc_vaapi' && job.options.respond_to?(:vaapi_device) &&
           job.options.vaapi_device.to_s.match?(/amd|radeon/i)
          out.concat(['-flags:v', '-global_header'])
        end

        out
      end
    end
  end
end
