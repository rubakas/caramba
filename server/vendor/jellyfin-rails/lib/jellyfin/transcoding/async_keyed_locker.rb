module Jellyfin
  module Transcoding
    # Per-key reentrant lock. Ports MediaBrowser.MediaEncoding/Transcoding/
    # TranscodeManager.cs's AsyncKeyedLocker<string> use — prevents two callers
    # from launching ffmpeg into the same output directory at the same time.
    #
    # Usage:
    #   AsyncKeyedLocker.instance.with('job-abc') { ...mutating work... }
    class AsyncKeyedLocker
      def self.instance = @instance ||= new

      def initialize
        @gate = Mutex.new
        @locks = {}
      end

      def with(key)
        mtx = @gate.synchronize { @locks[key] ||= Mutex.new }
        mtx.synchronize { yield }
      ensure
        @gate.synchronize { @locks.delete(key) if mtx && !mtx.locked? }
      end
    end
  end
end
