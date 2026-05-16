module Jellyfin
  module Encoding
    # Time-seek strategy. Mirrors EncodingHelper.cs's GetInputModifier / seek
    # placement logic.
    #
    # ffmpeg has two `-ss` modes that differ by argument position:
    #
    #   pre-input  ffmpeg -ss T -i input            (FAST: jump to nearest keyframe)
    #   post-input ffmpeg -i input -ss T            (ACCURATE: decode + discard)
    #
    # Fast seek is order-of-magnitude faster but lands on a keyframe and can be
    # several seconds off. Accurate seek is frame-perfect but pays a decoding
    # tax. We pick based on:
    #
    #   - stream-copying video → fast (we can't re-encode anyway)
    #   - burning text/PGS subtitles → accurate (subs need frame-perfect sync)
    #   - tonemapping HDR → accurate (filter chain has frame deps)
    #   - otherwise → fast
    #
    # Seek-by-segment: when restarting at segment N for HLS, the produced .ts
    # files have to be numbered starting at N (not 0) so the playlist indexes
    # match. ffmpeg's hls muxer takes `-hls_start_number_source datetime` or an
    # explicit `-start_number N`.
    module Seek
      module_function

      Plan = Struct.new(:pre_input, :post_input, :start_segment, keyword_init: true) do
        def empty? = pre_input.empty? && post_input.empty?
      end

      def plan_for(job, start_segment: 0)
        seconds = seek_seconds(job)
        return Plan.new(pre_input: [], post_input: [], start_segment: start_segment.to_i) if seconds.nil? || seconds <= 0

        accurate = accurate_seek?(job)
        flag = ['-ss', format('%.3f', seconds)]

        if accurate
          Plan.new(pre_input: [], post_input: flag, start_segment: start_segment.to_i)
        else
          Plan.new(pre_input: flag, post_input: [], start_segment: start_segment.to_i)
        end
      end

      # Args appended to the HLS output to make the first segment number == N
      # so that segment N+0 = the freshly-encoded slice, matching what the
      # playlist already advertised before the restart.
      def hls_segment_number_args(start_segment)
        return [] if start_segment.to_i.zero?
        ['-start_number', start_segment.to_s]
      end

      def accurate_seek?(job)
        return false if job.stream_copy_video?
        # NOTE: neither `burn_subtitles?` nor `hdr_input? + tonemap` is
        # alone a reason to use accurate seek for HLS output. Accurate
        # seek (`-ss` AFTER `-i`) decodes from frame 0 up to the target
        # before writing anything — for a non-zero resume on a 2 h source
        # that's MANY MINUTES of pure decode before the init segment
        # flushes, so the client always 504s before playback can start.
        # Verified 2026-05-16:
        #   - bitmap burn (Iron Giant @ resume 2028 s): never started
        #   - HDR tonemap (Devil Wears Prada @ resume 678 s): never
        #     started, ffmpeg stuck decoding 11+ minutes of 4K HEVC
        # Both filters operate frame-locally; landing on the keyframe
        # ≤ target and emitting from there is fine. hls.js bridges the
        # few seconds of slack via SourceBuffer.timestampOffset, same
        # mechanism it uses for every other segment restart.
        # Callers that genuinely need accurate seek (e.g. progressive
        # MP4 with no HLS container to absorb the offset) opt in via
        # the explicit option below.
        return true  if job.options.respond_to?(:force_accurate_seek) && job.options.force_accurate_seek
        false
      end

      def seek_seconds(job)
        ticks = job.start_time_ticks
        return nil if ticks.nil? || ticks.zero?
        ticks.to_f / Jellyfin::Probing::MediaSourceInfo::TICKS_PER_SECOND
      end
    end
  end
end
