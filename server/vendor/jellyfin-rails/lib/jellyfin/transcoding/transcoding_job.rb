require 'fileutils'

module Jellyfin
  module Transcoding
    # Tracks one running ffmpeg transcode. Mirrors MediaBrowser.MediaEncoding/
    # Transcoding/TranscodeManager.cs#TranscodingJob — the subset needed for HLS.
    class TranscodingJob
      attr_reader :id, :params, :dir, :playlist_path, :segment_template,
                  :cancellation_token
      attr_accessor :pid, :started_at, :last_ping_at, :stderr_path,
                    :restart_count, :cleaner, :throttler,
                    :start_segment, :last_served_segment, :ref_count,
                    :progress_reader, :live_stream_id, :media_source,
                    :fonts_dir,
                    :play_session_id, :is_user_paused

      def initialize(id:, params:, root_dir:)
        @id = id
        @params = params
        @dir = File.join(root_dir, id)
        FileUtils.mkdir_p(@dir)
        @playlist_path = File.join(@dir, 'master.m3u8')
        @segment_template = File.join(@dir, '%d.ts')
        @stderr_path = File.join(@dir, 'ffmpeg.log')
        @started_at = nil
        @last_ping_at = monotonic_now
        @restart_count = 0
        @cleaner = nil
        @throttler = nil
        # Restart-at-segment bookkeeping.
        @start_segment = 0
        @last_served_segment = 0
        # Shared-session refcount. The job survives as long as ref_count > 0
        # or until idle_for exceeds the configured timeout.
        @ref_count = 0
        @cancellation_token = CancellationToken.new
        @progress_reader = nil
        @live_stream_id = params[:live_stream_id]
        @media_source = nil
        @fonts_dir = nil
        # Mirrors TranscodingJob.PlaySessionId / IsUserPaused upstream
        # (MediaBrowser.MediaEncoding/Transcoding/TranscodeManager.cs).
        @play_session_id = params[:play_session_id]
        @is_user_paused = false
      end

      def attach!  = @ref_count += 1
      def detach!
        @ref_count = [@ref_count - 1, 0].max
      end

      # Rotates the ffmpeg log path so each restart writes to its own file.
      # Old files are preserved for postmortem of failed restarts.
      def rotate_log!
        @stderr_path = File.join(@dir, "ffmpeg.#{@restart_count}.log")
      end

      def segment_length_seconds
        (params[:segment_length] || 6).to_i
      end

      # Returns the timestamp (in seconds) at which ffmpeg should be (re)started
      # to satisfy a client requesting `segment_n`.
      def seek_seconds_for(segment_n)
        segment_n.to_i * segment_length_seconds
      end

      def alive?
        return false unless pid
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH, Errno::EPERM
        false
      end

      def kill!
        @cancellation_token.cancel!
        @progress_reader&.stop
        return unless alive?
        Process.kill('TERM', pid)
        deadline = monotonic_now + 5
        while alive? && monotonic_now < deadline
          sleep 0.05
        end
        Process.kill('KILL', pid) if alive?
      rescue Errno::ESRCH
        nil
      end

      # Helper for controllers: a snapshot of progress data suitable for JSON.
      def progress_snapshot
        return {} unless @progress_reader
        @progress_reader.snapshot.to_h_serializable
      end

      def cleanup!
        FileUtils.rm_rf(dir)
      end

      def ping!
        @last_ping_at = monotonic_now
      end

      def idle_for
        monotonic_now - last_ping_at
      end

      def segment_path(n)
        File.join(dir, "#{n}.ts")
      end

      private

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
