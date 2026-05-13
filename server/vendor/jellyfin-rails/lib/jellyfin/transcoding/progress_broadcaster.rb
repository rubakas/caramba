module Jellyfin
  module Transcoding
    # Periodically samples ffmpeg's progress reader and broadcasts updates over
    # ActionCable. Mirrors what upstream Jellyfin does over its WebSocket bus.
    #
    # Decoupled from ActionCable so non-Rails callers (or tests) can subscribe
    # via plain blocks: `ProgressBroadcaster.subscribe(job_id) { |snapshot| ... }`.
    # When ActionCable IS loaded, the controller wires the broadcaster to a
    # channel so the same stream lands in browsers.
    class ProgressBroadcaster
      INTERVAL = 1.0 # seconds between samples; matches ffmpeg's -progress cadence

      def self.instance
        @instance ||= new
      end

      def self.reset!
        @instance&.stop_all
        @instance = nil
      end

      def initialize
        @subscribers = Hash.new { |h, k| h[k] = [] }
        @threads = {}
        @mutex = Mutex.new
      end

      # Subscribes a plain block to a job's progress stream. Returns an
      # opaque ID so the caller can later unsubscribe.
      def subscribe(job_id, &block)
        sub_id = SecureRandom.hex(8)
        @mutex.synchronize do
          @subscribers[job_id] << [sub_id, block]
          start_thread(job_id) unless @threads.key?(job_id)
        end
        sub_id
      end

      def unsubscribe(job_id, sub_id)
        @mutex.synchronize do
          @subscribers[job_id].reject! { |id, _| id == sub_id }
          if @subscribers[job_id].empty?
            @subscribers.delete(job_id)
            stop_thread(job_id)
          end
        end
      end

      def stop_all
        @mutex.synchronize do
          @threads.each_key { |id| stop_thread(id) }
          @subscribers.clear
        end
      end

      private

      def start_thread(job_id)
        @threads[job_id] = Thread.new do
          loop do
            manager = TranscodeManager.instance
            job = manager.find(job_id)
            break unless job
            snapshot = job.progress_snapshot
            subs = @mutex.synchronize { @subscribers[job_id].dup }
            subs.each do |_id, blk|
              begin
                blk.call(snapshot)
              rescue StandardError
                # Subscribers must not crash the broadcast loop.
              end
            end
            sleep INTERVAL
          end
        rescue StandardError
          nil
        end
        @threads[job_id].report_on_exception = false
      end

      def stop_thread(job_id)
        t = @threads.delete(job_id)
        t&.kill
      end
    end
  end
end

require 'securerandom'
