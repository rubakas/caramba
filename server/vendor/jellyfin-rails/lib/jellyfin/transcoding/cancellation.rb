module Jellyfin
  module Transcoding
    # Cancellation tokens for transcoding jobs. A client-disconnect listener
    # holds a token and signals cancellation; TranscodingJob#kill! is invoked
    # asynchronously when the token fires.
    #
    # Mirrors CancellationToken behaviour in the upstream C# code. We don't
    # need its full async semantics — a thread-safe boolean + listener list
    # covers our use case.
    class CancellationToken
      def initialize
        @cancelled = false
        @listeners = []
        @mutex = Mutex.new
      end

      def cancelled? = @mutex.synchronize { @cancelled }

      # Signals cancellation. Idempotent — subsequent calls are no-ops.
      def cancel!
        listeners_to_fire = nil
        @mutex.synchronize do
          return if @cancelled
          @cancelled = true
          listeners_to_fire = @listeners.dup
        end
        # Run listeners outside the lock so a slow listener can't deadlock the
        # next caller.
        listeners_to_fire.each do |l|
          begin
            l.call
          rescue StandardError
            # Listeners must not crash other listeners.
          end
        end
      end

      def on_cancel(&block)
        @mutex.synchronize do
          if @cancelled
            block.call
          else
            @listeners << block
          end
        end
        self
      end
    end
  end
end
