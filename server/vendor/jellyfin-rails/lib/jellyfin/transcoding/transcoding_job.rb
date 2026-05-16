require 'fileutils'
require 'jellyfin/output/vod_playlist_generator'
require 'jellyfin/keyframes/extractor'
require 'jellyfin/media_encoder/probe'

module Jellyfin
  module Transcoding
    # Tracks one running ffmpeg transcode. Mirrors MediaBrowser.MediaEncoding/
    # Transcoding/TranscodeManager.cs#TranscodingJob — the subset needed for HLS.
    class TranscodingJob
      attr_reader :id, :params, :dir, :playlist_path, :segment_template,
                  :cancellation_token, :segment_container, :segment_extension,
                  :init_segment_path
      attr_accessor :pid, :started_at, :last_ping_at, :stderr_path,
                    :restart_count, :cleaner, :throttler,
                    :start_segment, :last_served_segment, :ref_count,
                    :progress_reader, :live_stream_id, :media_source,
                    :fonts_dir,
                    :play_session_id, :is_user_paused,
                    :aligned_to_client

      def initialize(id:, params:, root_dir:)
        @id = id
        @params = params
        @dir = File.join(root_dir, id)
        FileUtils.mkdir_p(@dir)
        @playlist_path = File.join(@dir, 'master.m3u8')
        # Segment container: 'ts' = MPEG-TS (h264/aac path), 'mp4' = fMP4
        # (HEVC/AV1 stream-copy path, mirrors what upstream Jellyfin
        # serves Safari for HEVC content — see network panel comparison).
        @segment_container = (params[:segment_container] || 'ts').to_s
        @segment_extension = (@segment_container == 'mp4') ? 'mp4' : 'ts'
        @segment_template = File.join(@dir, "%d.#{@segment_extension}")
        # `-1.mp4` is the canonical fMP4 init segment name (matches the
        # `EndpointPrefix-1{ext}` URI upstream Jellyfin emits in its
        # master playlist's `#EXT-X-MAP`). ffmpeg writes this only for
        # fmp4 jobs.
        @init_segment_path = (@segment_container == 'mp4') ? File.join(@dir, '-1.mp4') : nil
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
        # ensure_started pre-spawns ffmpeg at `-ss 0 -start_number 0` to
        # have a process running by the time the variant playlist is
        # requested. The player JS, however, seeks to the user's resume
        # time via `seekOnPlaybackStart` and hls.js then requests the
        # segment that covers that timestamp — segment 4 for a 24-second
        # resume on a 6-second-segment playlist. Without alignment, the
        # pre-spawned ffmpeg keeps emitting `0.mp4, 1.mp4, …` while the
        # client waits for `4.mp4`, which never arrives.
        #
        # `aligned_to_client` flips true the first time the segment
        # endpoint observes a client request. `TranscodeManager#request_segment`
        # uses that signal to restart ffmpeg at the requested segment
        # exactly once per session — subsequent requests fall through to
        # the gap-based seek-restart logic that mirrors upstream
        # `DynamicHlsController.GetDynamicSegment`.
        @aligned_to_client = false
      end

      def attach!  = @ref_count += 1
      def detach!
        @ref_count = [ @ref_count - 1, 0 ].max
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
      #
      # CRITICAL: for stream-copy paths the playlist uses keyframe-derived
      # VARIABLE segment durations (`VodPlaylistGenerator#compute_segments_from_keyframes`),
      # so segment N's position in the playlist is NOT `N * segment_length`.
      # Using the multiplication on those playlists made `-ss` land between
      # keyframes — fast-seek then snaps backward to the previous keyframe,
      # ffmpeg emits content from there, and hls.js positions it via
      # `timestampOffset` matching the playlist's nominal position for
      # segment N. The result is `video.currentTime` running AHEAD of the
      # rendered frames by exactly one keyframe interval (~4 s on most 24 fps
      # h264 rips), which the user sees as subtitles firing a few seconds
      # early after Resume. For equal-length playlists (no keyframe data,
      # full transcode with `-force_key_frames`) the multiplication is
      # correct and we keep it as the fallback.
      #
      # SECOND CATCH (kept tripping us): even when the nominal position IS
      # exactly at a keyframe, ffmpeg's matroska demuxer fast-seek has a
      # ~150ms backoff window — `av_index_search_timestamp` uses strict `<`
      # so a `-ss` matching a cue point lands on the PREVIOUS cue. Verified
      # empirically against The Office UK S01E01 (2026-05-16):
      #   -ss 852.852 → output first PTS = 848.848 (one keyframe back)
      #   -ss 852.999 → output first PTS = 852.852 ✓
      # We bias the seek slightly past the target keyframe so ffmpeg's
      # binary search picks the target as the largest-cue-strictly-less-than.
      # The bias is capped at half the next segment's duration so we never
      # cross into the following keyframe on tight GOPs.
      SEEK_KEYFRAME_BIAS = 0.5

      def seek_seconds_for(segment_n)
        n = segment_n.to_i
        return 0 if n.zero?
        durations = segment_durations
        return n * segment_length_seconds unless durations
        nominal = durations.first(n).sum
        # `durations[n]` is the duration of the segment we're starting (the
        # one containing the keyframe at `nominal`). Capping the bias at
        # half of it guarantees we stay before the NEXT keyframe.
        cap = (durations[n] || segment_length_seconds.to_f) * 0.4
        bias = [SEEK_KEYFRAME_BIAS, cap].min
        nominal + bias
      end

      # Cached array of #EXTINF durations matching the playlist the client
      # has. Returns nil when we can't derive a keyframe-based segmentation
      # (full transcode, non-MKV, missing Cues index), which signals
      # `seek_seconds_for` to fall back to `N * segment_length`.
      # Probes lazily because callers may need the durations before
      # `transcode_manager#probe_media_source` sets `job.media_source`.
      def segment_durations
        return @segment_durations if defined?(@segment_durations)
        @segment_durations = compute_segment_durations
      end

      def compute_segment_durations
        return nil unless params[:video_codec].to_s == 'copy'
        path = params[:path]
        return nil unless path
        kf = Jellyfin::Keyframes::Extractor.for(path)&.keyframe_seconds
        return nil if kf.nil? || kf.empty?
        total_seconds = media_source&.run_time_ticks.to_f /
                        Jellyfin::Output::VodPlaylistGenerator::TICKS_PER_SECOND
        if total_seconds <= 0
          probed = Jellyfin::MediaEncoder::Probe.from_path(path) rescue nil
          total_seconds = probed&.run_time_ticks.to_f /
                          Jellyfin::Output::VodPlaylistGenerator::TICKS_PER_SECOND
          return nil if total_seconds <= 0
        end
        Jellyfin::Output::VodPlaylistGenerator.send(
          :compute_segments_from_keyframes,
          keyframe_seconds: kf,
          total_duration_seconds: total_seconds,
          seek_seconds: 0,
          segment_length_seconds: segment_length_seconds.to_f
        )
      end
      private :compute_segment_durations

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
        # SIGCONT first: the throttler may have SIGSTOP'd ffmpeg to throttle
        # output. A stopped process queues SIGTERM and won't exit until
        # resumed. Without this, kill! sends TERM, waits 5s (alive? is true
        # because stopped processes are still "alive"), then sends KILL —
        # which SHOULD reap a stopped proc, but in practice we've seen
        # orphan ffmpegs survive in state T+. Resuming first lets ffmpeg
        # handle SIGTERM cleanly (flush stderr, write final frame, etc).
        begin
          Process.kill('CONT', pid)
        rescue Errno::ESRCH
          # Already gone.
        end
        Process.kill('TERM', pid)
        deadline = monotonic_now + 5
        while alive? && monotonic_now < deadline
          sleep 0.05
        end
        if alive?
          # Last-resort SIGKILL. Send CONT again in case the throttler
          # raced and SIGSTOP'd it between our CONT and the alive? check.
          begin
            Process.kill('CONT', pid)
          rescue Errno::ESRCH
            # ok
          end
          Process.kill('KILL', pid)
        end
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
        File.join(dir, "#{n}.#{segment_extension}")
      end

      private

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
