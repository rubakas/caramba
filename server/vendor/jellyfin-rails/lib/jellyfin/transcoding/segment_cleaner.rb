module Jellyfin
  module Transcoding
    # Deletes already-served segments from a running HLS transcode to keep disk
    # usage bounded. Ports MediaBrowser.MediaEncoding/Transcoding/TranscodeManager.cs
    # SegmentCleaner.
    #
    # Strategy: maintain a sliding window of N most-recent segments behind the
    # current playback head (we don't know the head precisely, so we keep
    # `keep_segments` worth of recent files and delete older).
    class SegmentCleaner
      DEFAULT_KEEP = 20  # ≈ 2 minutes at 6-sec segments
      DEFAULT_INTERVAL_S = 10

      def initialize(job, keep_segments: DEFAULT_KEEP, interval_s: DEFAULT_INTERVAL_S)
        @job = job
        @keep = keep_segments
        @interval = interval_s
        @thread = nil
        @stop = false
      end

      def start
        return if @thread&.alive?
        @stop = false
        @thread = Thread.new do
          until @stop
            begin
              sweep
            rescue StandardError
              # Best-effort; never crash the manager.
            end
            sleep @interval
          end
        end
      end

      def stop
        @stop = true
        @thread&.wakeup if @thread&.alive?
      end

      def sweep
        segments = Dir.glob(File.join(@job.dir, '*.ts')).sort_by { |f| File.basename(f, '.ts').to_i }
        return if segments.size <= @keep
        to_delete = segments[0...(segments.size - @keep)]
        to_delete.each { |f| File.delete(f) if File.exist?(f) }
      end
    end
  end
end
