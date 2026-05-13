require 'fileutils'

module Jellyfin
  module Transcoding
    # Parses ffmpeg's `-progress` pipe output. ffmpeg writes `key=value` lines
    # at regular intervals to whatever path is supplied; each "tick" ends with
    # `progress=continue` (or `progress=end` for the final frame).
    #
    # Mirrors the progress-reporting flow from TranscodeManager.cs's
    # `ReportTranscodingProgress`. We tail the pipe in a Thread and update an
    # in-memory Progress struct that controllers can read via the manager.
    #
    # The pipe path is a regular file: ffmpeg appends to it, we tail it. This
    # is more portable than a named-pipe (no mkfifo on Windows-y filesystems).
    class ProgressReader
      Progress = Struct.new(:frame, :fps, :bitrate, :total_size, :out_time_ms,
                            :dup_frames, :drop_frames, :speed, :status,
                            keyword_init: true) do
        def to_h_serializable
          to_h.compact
        end

        # Wall-clock seconds of source consumed.
        def out_time_seconds
          return 0.0 if out_time_ms.nil?
          out_time_ms.to_f / 1_000_000.0
        end
      end

      attr_reader :pipe_path, :progress, :thread

      def initialize(pipe_path)
        @pipe_path = pipe_path
        @progress = Progress.new
        @stop = false
        @thread = nil
        @mutex = Mutex.new
      end

      def args_for_ffmpeg
        ['-progress', pipe_path, '-nostats']
      end

      def start
        FileUtils.touch(pipe_path)
        @stop = false
        @thread = Thread.new { tail_loop }
        @thread.report_on_exception = false
        self
      end

      def stop
        @stop = true
        @thread&.join(0.5)
        @thread = nil
        self
      end

      def snapshot
        @mutex.synchronize { @progress.dup }
      end

      private

      def tail_loop
        File.open(pipe_path, 'r') do |f|
          buf = +''
          until @stop
            chunk = f.read_nonblock(4096, exception: false)
            if chunk == :wait_readable || chunk.nil?
              sleep 0.1
              next
            end
            buf << chunk
            while (newline = buf.index("\n"))
              process_line(buf[0...newline])
              buf = buf[(newline + 1)..]
            end
          end
        end
      rescue Errno::ENOENT, IOError
        # Pipe vanished — that's how we know ffmpeg exited.
      end

      def process_line(line)
        key, val = line.split('=', 2)
        return unless key && val
        @mutex.synchronize do
          case key
          when 'frame'        then @progress.frame       = val.to_i
          when 'fps'          then @progress.fps         = val.to_f
          when 'bitrate'      then @progress.bitrate     = val
          when 'total_size'   then @progress.total_size  = val.to_i
          when 'out_time_ms'  then @progress.out_time_ms = val.to_i
          when 'dup_frames'   then @progress.dup_frames  = val.to_i
          when 'drop_frames'  then @progress.drop_frames = val.to_i
          when 'speed'        then @progress.speed       = val
          when 'progress'     then @progress.status      = val
          end
        end
      end
    end
  end
end
