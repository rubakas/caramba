module Jellyfin
  module Encoding
    # Full stream-copy eligibility rules ported from
    # EncodingHelper.CanStreamCopyVideo / CanStreamCopyAudio. Each rule that
    # rejects records a reason so the controller can surface diagnostics.
    #
    # The caller passes an EncodingJobInfo + a ClientProfile (or no profile,
    # meaning "any HLS-compatible client"). Returns a struct.
    module StreamCopy
      Result = Struct.new(:eligible, :reasons, keyword_init: true) do
        def eligible? = eligible
      end

      module_function

      # ---- video ----

      def video?(job, profile: nil)
        reasons = []
        stream  = job.video_stream
        return Result.new(eligible: false, reasons: ['no_video_stream']) unless stream

        check_codec_match(reasons, stream, job)
        check_bit_depth(reasons, stream, profile)
        check_pixel_format(reasons, stream, profile)
        check_height(reasons, stream, job, profile)
        check_width(reasons, stream, job, profile)
        check_video_bitrate(reasons, stream, job, profile)
        check_framerate(reasons, stream, job, profile)
        check_profile(reasons, stream, profile)
        check_level(reasons, stream, profile)
        check_b_frames(reasons, stream, profile)
        check_ref_frames(reasons, stream, profile)
        check_anamorphic(reasons, stream, profile)
        check_interlaced(reasons, stream, profile)
        check_hdr(reasons, stream, profile)
        check_dovi(reasons, stream, profile)
        check_gop_closed(reasons, stream, profile)
        check_vfr(reasons, stream, profile)

        Result.new(eligible: reasons.empty?, reasons: reasons)
      end

      # ---- audio ----

      def audio?(job, profile: nil)
        reasons = []
        stream  = job.audio_stream
        return Result.new(eligible: false, reasons: ['no_audio_stream']) unless stream

        check_audio_codec(reasons, stream, job, profile)
        check_audio_channels(reasons, stream, job, profile)
        check_audio_sample_rate(reasons, stream, job, profile)
        check_audio_bitrate(reasons, stream, job, profile)
        check_audio_bit_depth(reasons, stream, profile)

        Result.new(eligible: reasons.empty?, reasons: reasons)
      end

      # ---- rule helpers ----

      def check_codec_match(reasons, stream, job)
        return if codec_alias?(stream.codec, job.output_video_codec)
        reasons << "codec_mismatch=#{stream.codec}≠#{job.output_video_codec}"
      end

      def check_bit_depth(reasons, stream, profile)
        return unless profile
        reasons << 'bit_depth_10_unsupported' if stream.respond_to?(:ten_bit?) && stream.ten_bit? && !profile.supports_10bit
      end

      def check_pixel_format(reasons, stream, _profile)
        # 4:4:4 chroma not playable by most clients.
        reasons << 'pixel_format_yuv444' if stream.pixel_format.to_s.include?('yuv444')
      end

      def check_height(reasons, stream, job, profile)
        if job.output_height && stream.height && stream.height > job.output_height
          reasons << "height_exceeds=#{stream.height}>#{job.output_height}"
        end
        return unless profile&.max_video_height && stream.height
        reasons << "client_max_height=#{profile.max_video_height}" if stream.height > profile.max_video_height
      end

      def check_width(reasons, stream, job, profile)
        if job.output_width && stream.width && stream.width > job.output_width
          reasons << "width_exceeds=#{stream.width}>#{job.output_width}"
        end
        return unless profile&.max_video_width && stream.width
        reasons << "client_max_width=#{profile.max_video_width}" if stream.width > profile.max_video_width
      end

      def check_video_bitrate(reasons, stream, job, profile)
        target = job.output_video_bitrate
        if target && stream.bit_rate && stream.bit_rate > target * 1.1
          reasons << "bitrate_exceeds=#{stream.bit_rate}>#{target}"
        end
        return unless profile&.max_video_bitrate && stream.bit_rate
        reasons << "client_max_bitrate=#{profile.max_video_bitrate}" if stream.bit_rate > profile.max_video_bitrate
      end

      def check_framerate(reasons, stream, job, profile)
        if job.max_framerate && stream.frame_rate && stream.frame_rate > job.max_framerate + 0.1
          reasons << "framerate_exceeds=#{stream.frame_rate}>#{job.max_framerate}"
        end
        return unless profile&.max_video_fps && stream.frame_rate
        reasons << "client_max_fps=#{profile.max_video_fps}" if stream.frame_rate > profile.max_video_fps + 0.5
      end

      def check_profile(reasons, stream, profile)
        return unless profile && stream.codec.to_s.downcase == 'h264' && !profile.h264_profiles.empty?
        ok = profile.h264_profiles.include?(stream.profile.to_s.downcase)
        reasons << "h264_profile=#{stream.profile}" unless ok
      end

      def check_level(reasons, stream, profile)
        return unless profile&.h264_level && stream.codec.to_s.downcase == 'h264' && stream.level
        reasons << "h264_level=#{stream.level}>#{profile.h264_level}" if stream.level > profile.h264_level
      end

      def check_b_frames(reasons, stream, profile)
        return unless profile&.max_video_b_frames
        # ffprobe's `has_b_frames` is the per-codec max number of B-frames the
        # decoder must hold between reference frames — directly comparable to
        # the device-profile cap. nil = ffprobe didn't report it (older builds
        # on audio-only streams); treat as 0.
        actual = stream.has_b_frames.to_i
        reasons << "b_frames=#{actual}>#{profile.max_video_b_frames}" if actual > profile.max_video_b_frames
      end

      def check_ref_frames(reasons, stream, profile)
        return unless profile.respond_to?(:max_ref_frames) && profile.max_ref_frames && stream.refs
        reasons << "ref_frames=#{stream.refs}>#{profile.max_ref_frames}" if stream.refs.to_i > profile.max_ref_frames
      end

      def check_anamorphic(reasons, stream, profile)
        return unless profile && !profile.supports_anamorphic
        reasons << 'anamorphic' if stream.respond_to?(:anamorphic?) && stream.anamorphic?
      end

      def check_interlaced(reasons, stream, profile)
        return unless profile && !profile.supports_interlaced
        reasons << 'interlaced' if stream.is_interlaced
      end

      def check_hdr(reasons, stream, profile)
        return unless profile && !profile.supports_hdr
        reasons << 'hdr' if stream.hdr?
      end

      def check_dovi(reasons, stream, profile)
        return unless profile && stream.video_range_type.to_s == 'DOVI' && !profile.supports_dovi
        reasons << 'dovi'
      end

      def check_gop_closed(reasons, stream, profile)
        # Only the open-GOP case is a problem and only for clients/players that
        # don't tolerate it. We trust the probe answer when it's been filled.
        # When unknown (nil) we don't reject — being conservative would block
        # too many sources.
        return if stream.gop_closed.nil?
        return if stream.gop_closed
        return if profile.nil? || (profile.respond_to?(:supports_open_gop) && profile.supports_open_gop)
        reasons << 'open_gop'
      end

      def check_vfr(reasons, stream, profile)
        # HLS expects roughly-constant frame rate. VFR sources break segment
        # alignment. Most clients tolerate it but force-transcode is safer.
        return unless profile.respond_to?(:supports_vfr) && !profile.supports_vfr
        reasons << 'vfr' if stream.is_vfr
      end

      def check_audio_codec(reasons, stream, job, profile)
        unless codec_alias?(stream.codec, job.output_audio_codec)
          reasons << "audio_codec=#{stream.codec}≠#{job.output_audio_codec}"
        end
        return unless profile
        ok = profile.audio_codecs.any? { |c| codec_alias?(stream.codec, c) }
        reasons << "client_audio_codec=#{stream.codec}" unless ok
      end

      def check_audio_channels(reasons, stream, job, profile)
        if job.output_audio_channels && stream.channels && stream.channels > job.output_audio_channels
          reasons << "audio_channels=#{stream.channels}>#{job.output_audio_channels}"
        end
        return unless profile&.max_audio_channels && stream.channels
        reasons << "client_max_audio_channels=#{profile.max_audio_channels}" if stream.channels > profile.max_audio_channels
      end

      def check_audio_sample_rate(reasons, stream, job, _profile)
        return unless stream.sample_rate
        if job.output_audio_sample_rate && stream.sample_rate != job.output_audio_sample_rate
          # Mismatched sample rate forces resampling.
          reasons << "audio_sample_rate=#{stream.sample_rate}≠#{job.output_audio_sample_rate}"
        end
      end

      def check_audio_bitrate(reasons, stream, job, _profile)
        return unless stream.bit_rate && job.output_audio_bitrate
        reasons << "audio_bitrate=#{stream.bit_rate}>#{job.output_audio_bitrate}" if stream.bit_rate > job.output_audio_bitrate * 1.2
      end

      def check_audio_bit_depth(reasons, stream, profile)
        return unless profile&.max_audio_bit_depth && stream.bit_depth
        return unless stream.bit_depth > profile.max_audio_bit_depth
        reasons << "audio_bit_depth=#{stream.bit_depth}>#{profile.max_audio_bit_depth}"
      end

      def codec_alias?(a, b)
        a = a.to_s.downcase
        b = b.to_s.downcase
        return true if a == b
        groups = [%w[h264 avc libx264], %w[h265 hevc libx265], %w[av1 av01 libsvtav1 libaom-av1],
                  %w[aac libfdk_aac], %w[mp3 libmp3lame], %w[opus libopus],
                  %w[ac3 a_ac3], %w[eac3 a_eac3]]
        groups.any? { |g| g.include?(a) && g.include?(b) }
      end
    end
  end
end
