module Jellyfin
  module Transcoding
    # Tracks open live-stream "sources" (an IPTV pull, an HDHomeRun tuner, an
    # rtsp camera, etc.). Mirrors LiveStreamId / CloseLiveStream from upstream:
    # multiple ffmpeg transcodes can share a single live source, and the
    # source is closed only when the last consumer drops.
    #
    # Each live source registers a `close` block that is called when the last
    # consumer detaches. Typical close blocks: shut down a tuner, release a
    # network socket, signal an upstream service.
    class LiveStreamRegistry
      def self.instance
        @instance ||= new
      end

      def self.reset!
        @instance = nil
      end

      def initialize
        @streams = {}
        @mutex = Mutex.new
      end

      # Registers a live stream and runs the consumer block while holding the
      # reference. When the block returns the refcount drops; the close proc
      # fires when no consumers remain.
      def register(stream_id, close:)
        @mutex.synchronize do
          entry = @streams[stream_id] ||= { count: 0, close: close }
          entry[:count] += 1
        end
      end

      def release(stream_id)
        to_close = nil
        @mutex.synchronize do
          entry = @streams[stream_id]
          return unless entry
          entry[:count] -= 1
          if entry[:count] <= 0
            to_close = entry[:close]
            @streams.delete(stream_id)
          end
        end
        to_close&.call
      end

      def open?(stream_id) = @mutex.synchronize { @streams.key?(stream_id) }
      def refcount(stream_id) = @mutex.synchronize { @streams.dig(stream_id, :count) || 0 }
      def count = @mutex.synchronize { @streams.size }
    end
  end
end
