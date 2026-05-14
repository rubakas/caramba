module Jellyfin
  module Keyframes
    # Memoizes keyframe extraction by (path, mtime, size). A change to
    # the underlying file invalidates automatically; otherwise repeated
    # /variant.m3u8 requests within a session reuse the parse instead
    # of re-reading the MKV index every time.
    module Cache
      MAX_ENTRIES = 256

      @mutex = Mutex.new
      @store = {}

      module_function

      def fetch(path)
        stat = (File.stat(path) rescue nil)
        return yield unless stat
        key = [ path, stat.mtime.to_i, stat.size ]
        cached = @mutex.synchronize { @store[key] }
        return cached if cached
        value = yield
        @mutex.synchronize do
          @store[key] = value
          @store.shift while @store.size > MAX_ENTRIES
        end
        value
      end

      def clear!
        @mutex.synchronize { @store.clear }
      end
    end
  end
end
