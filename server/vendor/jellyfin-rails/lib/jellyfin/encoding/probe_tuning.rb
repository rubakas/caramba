module Jellyfin
  module Encoding
    # `-analyzeduration` / `-probesize` tuning. ffmpeg's defaults are aggressive
    # (low values) which works for most local files but stumbles on:
    #
    #   - MPEG-TS over network where the first PAT/PMT arrive late
    #   - High-bitrate UHD content where the codec metadata isn't parsed in
    #     the default 5MB window
    #   - Live streams where keyframes are sparse
    #
    # Mirrors EncodingHelper.cs's per-source probe-size scaling. Returns args
    # that go BEFORE the `-i` input flag.
    module ProbeTuning
      # Default probe budget — generous compared to ffmpeg's default 5MB / 5s.
      DEFAULT_PROBESIZE_BYTES   = 50 * 1024 * 1024 # 50 MB
      DEFAULT_ANALYZE_MICROSECS = 10_000_000       # 10 s

      module_function

      def input_args(job)
        size, dur = budget_for(job)
        ['-probesize', size.to_s, '-analyzeduration', dur.to_s]
      end

      # Returns [probesize_bytes, analyzeduration_microseconds].
      def budget_for(job)
        source = job.media_source
        bitrate = source.bit_rate.to_i

        # Generous defaults if the bitrate is unknown.
        return [DEFAULT_PROBESIZE_BYTES, DEFAULT_ANALYZE_MICROSECS] if bitrate.zero?

        # Scale up for >25 Mbps content (typical 4K). 4 seconds of bitstream
        # comfortably contains a GOP for any sane source.
        if bitrate > 25_000_000
          return [bitrate / 8 * 4, 20_000_000]
        end
        # Reduce for low-bitrate audio-only or web sources where the default
        # is more than needed.
        if bitrate < 1_000_000
          return [10 * 1024 * 1024, 5_000_000]
        end
        [DEFAULT_PROBESIZE_BYTES, DEFAULT_ANALYZE_MICROSECS]
      end
    end
  end
end
