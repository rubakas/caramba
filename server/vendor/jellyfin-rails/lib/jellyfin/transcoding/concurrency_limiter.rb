module Jellyfin
  module Transcoding
    # Bounded concurrent-transcode cap. Mirrors the upstream semaphore that
    # ensures we never have more than N ffmpeg processes running at once.
    #
    # When the cap is hit, callers can either:
    #   - wait_or_raise! — raise after a timeout (good for API callers)
    #   - acquire        — block until a slot frees (good for queues)
    #
    # Slots are released on job stop. The TranscodeManager wires acquire/
    # release into ensure_started / stop! / reap_idle.
    class ConcurrencyLimiter
      class CapExceeded < StandardError; end

      def initialize(max_concurrent: 0)
        @max = max_concurrent.to_i
        @held = {}
        @mutex = Mutex.new
        @cond = ConditionVariable.new
      end

      def configure(max_concurrent:)
        @mutex.synchronize { @max = max_concurrent.to_i }
      end

      def in_flight = @mutex.synchronize { @held.size }
      def max       = @max

      # `unlimited?` — a 0 or negative cap disables the gate entirely. Useful
      # for tests that don't want concurrency policing.
      def unlimited? = @max <= 0

      def acquire(job_id, timeout: 30)
        return if unlimited?
        deadline = monotonic_now + timeout
        @mutex.synchronize do
          while @held.size >= @max && !@held.key?(job_id)
            remaining = deadline - monotonic_now
            raise CapExceeded, "transcode cap reached (#{@max}); waited #{timeout}s" if remaining <= 0
            @cond.wait(@mutex, remaining)
          end
          @held[job_id] = monotonic_now
        end
      end

      def release(job_id)
        return if unlimited?
        @mutex.synchronize do
          @held.delete(job_id)
          @cond.signal
        end
      end

      # Re-entrant safety: held? returns true when the job already has a slot.
      def held?(job_id)
        @mutex.synchronize { @held.key?(job_id) }
      end

      private

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
