module Jellyfin
  module Transcoding
    # Watches a running HLS transcode and pauses ffmpeg via SIGSTOP when it has
    # buffered too far ahead of the playback head, resuming via SIGCONT when
    # the head catches up. Ports TranscodingThrottler from upstream — upstream
    # uses ffmpeg's stdin "p" key; we use signals because they're more reliable
    # across ffmpeg builds and don't require writable stdin.
    #
    # The estimated playback head comes from the most-recently *served* segment.
    # The transcode head is the highest segment file on disk. When their gap in
    # seconds exceeds `throttle_seconds`, we pause.
    class Throttler
      DEFAULT_INTERVAL_S = 5

      def initialize(job, segment_length:, throttle_seconds:, interval_s: DEFAULT_INTERVAL_S)
        @job = job
        @segment_length = segment_length
        @threshold = throttle_seconds
        @interval = interval_s
        @paused = false
        @last_served = -1
        @thread = nil
        @stop = false
      end

      # Called by the controller every time a segment is delivered to the client.
      def note_served(segment_id)
        @last_served = segment_id if segment_id > @last_served
        resume! if @paused # any client activity wakes ffmpeg
      end

      def start
        return if @thread&.alive?
        @stop = false
        @thread = Thread.new do
          until @stop
            begin
              tick
            rescue StandardError
              # Best-effort.
            end
            sleep @interval
          end
        end
      end

      def stop
        @stop = true
        resume!
        @thread&.wakeup if @thread&.alive?
      end

      private

      def tick
        return if @stop
        return unless @job.alive?
        # Explicit user pause (ported from TranscodingJob.IsUserPaused upstream)
        # overrides the read-ahead heuristic. Stay paused until the client
        # clears the flag via /sessions/playing/progress with paused=false.
        if @job.respond_to?(:is_user_paused) && @job.is_user_paused
          pause! unless @paused
          return
        end
        head = current_head
        return if head.nil?
        ahead = (head - @last_served) * @segment_length
        if !@paused && ahead > @threshold
          pause!
        elsif @paused && ahead < (@threshold / 2)
          resume!
        end
      end

      def current_head
        files = Dir.glob(File.join(@job.dir, '*.ts'))
        return nil if files.empty?
        files.map { |f| File.basename(f, '.ts').to_i }.max
      end

      def pause!
        return unless @job.pid
        # Double-check the stop flag — the tick that called us might have
        # raced with stop() and we're about to SIGSTOP a process that's
        # being torn down. Without this, kill! later finds the process
        # still suspended (T+) and SIGTERM gets queued indefinitely.
        return if @stop
        Process.kill('STOP', @job.pid)
        @paused = true
      rescue Errno::ESRCH, Errno::EPERM
        @paused = false
      end

      def resume!
        return unless @paused && @job.pid
        Process.kill('CONT', @job.pid)
        @paused = false
      rescue Errno::ESRCH, Errno::EPERM
        @paused = false
      end
    end
  end
end
