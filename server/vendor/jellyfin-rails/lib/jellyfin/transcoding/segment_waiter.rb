module Jellyfin
  module Transcoding
    # Ports the wait-for-segment pattern from
    # Jellyfin.Api/Controllers/DynamicHlsController.cs:1942-1964 — loops on 100ms
    # sleeps until the requested segment file exists. Returns early once the *next*
    # segment also exists (cheap signal that ffmpeg has moved past).
    module SegmentWaiter
      DEFAULT_POLL_MS = 100
      DEFAULT_TIMEOUT_S = 30

      module_function

      def wait(job, segment_id, poll_ms: DEFAULT_POLL_MS, timeout_s: DEFAULT_TIMEOUT_S)
        target = job.segment_path(segment_id)
        next_one = job.segment_path(segment_id + 1)
        deadline = monotonic_now + timeout_s
        loop do
          return target if File.exist?(target) && File.exist?(next_one)
          if !job.alive? && File.exist?(target)
            return target
          end
          return nil if monotonic_now > deadline
          sleep(poll_ms / 1000.0)
        end
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
