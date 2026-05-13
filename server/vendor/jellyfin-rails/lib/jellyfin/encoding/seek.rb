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
        return true  if job.burn_subtitles?
        return true  if job.hdr_input? && job.options.enable_tonemapping
        # Custom callers can mark precise seek explicitly via the option.
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
