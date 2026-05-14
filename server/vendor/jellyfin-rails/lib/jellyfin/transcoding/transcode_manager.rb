require 'fileutils'
require 'jellyfin/transcoding/args_builder'
require 'jellyfin/transcoding/transcoding_job'
require 'jellyfin/transcoding/segment_waiter'
require 'jellyfin/transcoding/segment_cleaner'
require 'jellyfin/transcoding/throttler'
require 'jellyfin/transcoding/async_keyed_locker'
require 'jellyfin/encoding/encoding_helper'
require 'jellyfin/encoding/encoding_job_info'
require 'jellyfin/encoding/encoding_options'
require 'jellyfin/media_encoder/probe'
require 'jellyfin/media_encoder/encoder'

module Jellyfin
  module Transcoding
    # Ports MediaBrowser.MediaEncoding/Transcoding/TranscodeManager.cs.
    # Tracks active ffmpeg processes by job id, reaps idle ones, cleans up segments.
    #
    # Singleton-per-process. Pulls config lazily so tests can swap ffmpeg_path.
    class TranscodeManager
      def self.instance
        @instance ||= new
      end

      def self.reset!
        @instance&.shutdown!
        @instance = nil
      end

      def initialize
        @jobs = {}
        @mutex = Mutex.new
        @reaper = nil
        @concurrency = ConcurrencyLimiter.new(
          max_concurrent: Jellyfin::Rails.configuration.respond_to?(:max_concurrent_transcodes) ?
            Jellyfin::Rails.configuration.max_concurrent_transcodes.to_i : 0
        )
        wipe_stale_cache_dir
      end

      # Exposes the limiter so tests + admin tooling can inspect / tune it.
      attr_reader :concurrency

      # Mirrors TranscodeManager.cs DeleteEncodedMediaCache — wipes the transcode
      # directory on boot so abandoned segment trees from a prior process don't
      # accumulate forever.
      def wipe_stale_cache_dir
        dir = Jellyfin::Rails.configuration.resolved_transcode_dir.to_s
        return unless File.directory?(dir)
        Dir.children(dir).each do |entry|
          full = File.join(dir, entry)
          # Subtitle cache is path-keyed and survives — keep it across restarts.
          next if entry == 'subs'
          FileUtils.rm_rf(full)
        end
      rescue StandardError
        # Best-effort.
      end

      def jobs = @mutex.synchronize { @jobs.values.dup }

      # Returns an existing job for these params or starts a new one. The job id is
      # derived from the params so identical requests share an output directory.
      #
      # `attach: true` (default) increments the job's refcount; pair every
      # `ensure_started` with a `detach!(id)` when the client disconnects.
      # Shared sessions: identical params from N clients all attach to the same
      # ffmpeg process, and the process keeps running as long as any client is
      # still subscribed.
      def ensure_started(id:, params:, attach: true)
        # Outer per-key lock prevents two threads from spawning ffmpeg into the
        # same output dir simultaneously. Inside the per-key lock we still take
        # the manager-wide mutex for table mutations.
        AsyncKeyedLocker.instance.with("job:#{id}") do
          @mutex.synchronize do
            existing = @jobs[id]
            if existing && existing.alive?
              existing.ping!
              existing.attach! if attach
              return existing
            end
            stop_job_internals(@jobs[id])
            @jobs[id]&.cleanup!
            job = TranscodingJob.new(id: id, params: params, root_dir: transcode_dir)
            # Bound concurrent transcodes — raises CapExceeded if we hit the
            # limit and timeout expires waiting for a slot.
            @concurrency.acquire(id, timeout: 10)
            prewarm_attachments(job)
            spawn_ffmpeg(job)
            start_supervisors(job)
            job.attach! if attach
            @jobs[id] = job
            ensure_reaper!
            job
          end
        end
      end

      # Synchronously extracts MKV font attachments before the first ffmpeg
      # spawn, so the burn-in filter has the fonts available at filter-init.
      def prewarm_attachments(job)
        job.fonts_dir = AttachmentPrewarm.call(job)
      rescue StandardError
        # Pre-warm is best-effort; don't fail the job if it can't reach ffmpeg.
        nil
      end

      # Releases this client's reference to a shared session. When the count
      # reaches zero the job is still kept around for `idle_timeout` to give a
      # reconnecting client a chance to resume without re-encoding.
      def detach!(id)
        @mutex.synchronize { @jobs[id]&.detach! }
      end

      # Ports TranscodeManager.PingTranscodingJob (upstream lines 117-143).
      # Finds every job carrying the given play-session id, updates its
      # `IsUserPaused` flag (when supplied), and bumps `last_ping_at`. The
      # latter prevents the idle reaper from killing a paused-but-attentive
      # session.
      def ping_session(play_session_id, is_user_paused: nil)
        return if play_session_id.to_s.empty?
        @mutex.synchronize do
          @jobs.each_value do |job|
            next unless job.play_session_id == play_session_id
            job.is_user_paused = is_user_paused unless is_user_paused.nil?
            job.ping!
          end
        end
      end

      # Signals cancellation for the job's token. The listener installed in
      # `spawn_ffmpeg` releases the concurrency slot and stops the progress
      # reader; full teardown happens via `stop!`.
      def cancel!(id)
        job = @mutex.synchronize { @jobs[id] }
        job&.cancellation_token&.cancel!
        stop!(id)
      end

      # Called when a client requests a segment that may be ahead of where
      # ffmpeg currently sits. If the gap exceeds the restart threshold, the
      # current process is killed and ffmpeg is re-spawned with -ss pointing at
      # the requested segment. Mirrors TranscodeManager.cs's seek-on-restart
      # behavior.
      RESTART_GAP_SEGMENTS = 10

      def request_segment(id, segment_n)
        AsyncKeyedLocker.instance.with("job:#{id}") do
          @mutex.synchronize do
            job = @jobs[id]
            return nil unless job

            current = current_segment_for(job)
            gap = segment_n.to_i - current
            if gap >= RESTART_GAP_SEGMENTS
              restart_at_segment(job, segment_n.to_i)
            end
            job.ping!
            job.last_served_segment = segment_n.to_i
            job
          end
        end
      end

      # Called by the controller every time a segment is delivered to a client.
      def note_segment_served(id, segment_id)
        job = find(id)
        job&.throttler&.note_served(segment_id)
        job&.ping!
      end

      def find(id) = @mutex.synchronize { @jobs[id] }

      # Port of TranscodeManager.GetTranscodingJob(playSessionId) (cs:100).
      # Returns the first job carrying the given play-session id.
      def find_by_session(play_session_id)
        return nil if play_session_id.to_s.empty?
        @mutex.synchronize do
          @jobs.values.find { |j| j.play_session_id == play_session_id }
        end
      end

      # Port of TranscodeManager.GetTranscodingJob(path, type) (cs:109). Looks
      # up an active job by output directory (a stable per-job path) optionally
      # filtered by an output-type hint stored in params.
      def find_by_path(path, type: nil)
        return nil if path.to_s.empty?
        @mutex.synchronize do
          @jobs.values.find do |j|
            j.dir == path.to_s &&
              (type.nil? || j.params[:type].to_s == type.to_s)
          end
        end
      end

      # Port of TranscodeManager.KillTranscodingJobs(deviceId, playSessionId,
      # deleteFiles) (cs:194). Stops every job matching the (device_id OR
      # play_session_id) filter and calls the `delete_files` predicate to
      # decide whether the job's output files should be wiped. Predicate
      # signature `path -> bool` mirrors upstream's `Func<string, bool>`.
      def kill_transcoding_jobs(device_id: nil, play_session_id: nil, delete_files: ->(_path) { true })
        targets = @mutex.synchronize do
          @jobs.values.select do |j|
            if play_session_id && !play_session_id.empty?
              j.play_session_id == play_session_id
            elsif device_id && !device_id.empty?
              j.params[:device_id] == device_id
            else
              false
            end
          end
        end

        targets.each do |job|
          job.cancellation_token.cancel!
          @mutex.synchronize do
            @jobs.delete(job.id)
            stop_job_internals(job)
            job.kill!
            release_live_stream_for(job) if job.live_stream_id
            @concurrency.release(job.id)
          end
          job.cleanup! if delete_files.call(job.dir)
        end
        targets.size
      end

      def stop!(id)
        @mutex.synchronize do
          job = @jobs.delete(id)
          stop_job_internals(job)
          job&.kill!
          release_live_stream_for(job) if job
          job&.cleanup!
          @concurrency.release(id)
        end
      end

      def release_live_stream_for(job)
        return unless job.live_stream_id
        LiveStreamRegistry.instance.release(job.live_stream_id)
      end

      def shutdown!
        @mutex.synchronize do
          @jobs.each_value do |j|
            stop_job_internals(j)
            j.kill!
            j.cleanup!
          end
          @jobs.clear
        end
        @reaper&.kill
        @reaper = nil
      end

      def reap_idle
        idle_timeout = Jellyfin::Rails.configuration.idle_timeout
        @mutex.synchronize do
          @jobs.values.each do |job|
            # Idle threshold is checked FIRST and ignores ref_count.
            # ref_count is a shared-session attach counter; in practice
            # it grows by one on every segment request (each call to
            # `ensure_started` auto-attaches) and is never decremented on
            # client disconnect — so an orphaned ffmpeg keeps ref_count
            # positive forever. Upstream Jellyfin gates kill on HTTP-level
            # activity instead (TranscodeManager.cs:174 OnTranscodeKillTimerStopped
            # fires after PingTimeout = 60s regardless of any per-job
            # reference counting). `idle_for` here is the time since the
            # last segment was served — same signal.
            if job.idle_for > idle_timeout
              @jobs.delete(job.id)
              stop_job_internals(job)
              job.kill!
              job.cleanup!
              next
            end
            unless job.alive?
              # Auto-restart: ffmpeg died while the job was still recent.
              # Mirrors upstream's restart-on-crash behavior (capped).
              if job.restart_count < 3 && job.idle_for < 30
                job.restart_count += 1
                spawn_ffmpeg(job)
              else
                @jobs.delete(job.id)
                stop_job_internals(job)
                job.cleanup!
              end
            end
          end
        end
      end

      def start_supervisors(job)
        opts = Jellyfin::Encoding::EncodingOptions.new
        seg_len = (job.params[:segment_length] || Jellyfin::Rails.configuration.segment_length).to_i
        # SegmentCleaner is only safe for live streams (sliding window).
        # For VOD playback the controller serves a pre-generated playlist
        # that references every segment; if the cleaner deletes segment
        # N while Safari seeks back to it, SegmentWaiter waits 30s for a
        # file ffmpeg won't recreate, then the segment endpoint 504s and
        # Safari surfaces MEDIA_ERR_SRC_NOT_SUPPORTED.
        if live_segmented?(job)
          job.cleaner = SegmentCleaner.new(job).tap(&:start)
        end
        job.throttler = Throttler.new(job, segment_length: seg_len,
                                            throttle_seconds: opts.throttle_seconds,
                                            interval_s: opts.throttle_delay_seconds).tap(&:start)
      end

      # Treats a probe-able runtime as VOD, missing runtime as live.
      # Matches `EncodingHelper#live_segmented?`. Probes lazily so we
      # don't depend on `job.media_source` being set elsewhere.
      def live_segmented?(job)
        media_source = job.media_source || probe_media_source(job)
        return true unless media_source
        rtt = media_source.respond_to?(:run_time_ticks) ? media_source.run_time_ticks : nil
        rtt.nil? || rtt.to_i.zero?
      end

      def probe_media_source(job)
        path = job.params[:path]
        return nil unless path && File.exist?(path)
        job.media_source = Jellyfin::MediaEncoder::Probe.from_path(path)
      rescue StandardError
        nil
      end

      def stop_job_internals(job)
        return unless job
        job.cleaner&.stop
        job.throttler&.stop
        job.cleaner = nil
        job.throttler = nil
      end

      private

      def transcode_dir
        dir = Jellyfin::Rails.configuration.resolved_transcode_dir.to_s
        FileUtils.mkdir_p(dir)
        dir
      end

      def spawn_ffmpeg(job)
        # Set up the progress pipe BEFORE building args so the progress flags
        # get spliced into the command line.
        progress_pipe = File.join(job.dir, 'progress.txt')
        job.progress_reader = ProgressReader.new(progress_pipe)

        args = build_args(job) + job.progress_reader.args_for_ffmpeg
        cmd = [Jellyfin::Rails.configuration.ffmpeg_path, *args]
        stderr = File.open(job.stderr_path, 'w')
        job.pid = Process.spawn(*cmd, out: stderr, err: stderr)
        job.started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        stderr.close

        job.progress_reader.start

        # When the job's cancellation token fires (e.g., client disconnect),
        # terminate the ffmpeg process. The mutex around @jobs prevents the
        # listener from racing with stop!.
        job.cancellation_token.on_cancel do
          @concurrency.release(job.id)
        end

        # Reap zombies in background.
        Thread.new(job.pid) do |pid|
          Process.waitpid(pid)
        rescue Errno::ECHILD, Errno::ESRCH
          nil
        end
      end

      # Kills ffmpeg, wipes the stale segment tree, rotates the log, then re-
      # spawns starting at `segment_n`. Mirrors upstream's seek-on-restart.
      def restart_at_segment(job, segment_n)
        job.kill!
        stop_job_internals(job)
        # Wipe stale segments — they were produced at the old start offset and
        # their numbering wraps once we restart at a new -ss.
        Dir.glob(File.join(job.dir, '*.ts')).each { |f| FileUtils.rm_f(f) }
        FileUtils.rm_f(job.playlist_path)
        job.restart_count += 1
        job.rotate_log!
        job.start_segment = segment_n
        spawn_ffmpeg(job)
        start_supervisors(job)
      end

      def current_segment_for(job)
        # Inspect the segment dir for the highest-numbered .ts file. This is
        # cheaper than parsing the playlist and accurate to within a segment.
        files = Dir.glob(File.join(job.dir, '*.ts'))
        return job.start_segment if files.empty?
        files.map { |f| File.basename(f, '.ts').to_i }.max + job.start_segment
      end

      # Build ffmpeg args via the EncodingHelper port. Falls back to the hand-
      # rolled ArgsBuilder if probing fails or the caller passes :simple => true.
      def build_args(job)
        return legacy_args(job) if job.params[:simple]

        begin
          source = Jellyfin::MediaEncoder::Probe.from_path(job.params[:path])
        rescue StandardError
          return legacy_args(job)
        end

        info = Jellyfin::Encoding::EncodingJobInfo.new(
          media_source: source,
          options: build_encoding_options(job),
          output_video_codec: encoder_target(job.params[:video_codec], 'libx264'),
          output_audio_codec: encoder_target(job.params[:audio_codec], 'aac'),
          output_video_bitrate: resolve_video_bitrate(job.params, source),
          output_audio_bitrate: (job.params[:audio_bitrate] || 128_000).to_i,
          output_audio_channels: job.params[:audio_channels]&.to_i,
          output_height: job.params[:max_height]&.to_i,
          segment_length: (job.params[:segment_length] || Jellyfin::Rails.configuration.segment_length).to_i,
          start_time_ticks: seek_ticks_for(job),
          video_stream: select_video_stream(source, job.params[:video_track]),
          audio_stream: select_audio_stream(source, job.params[:audio_track]),
          subtitle_stream: select_subtitle_stream(source, job.params[:subtitle_track]),
          subtitle_method: (job.params[:subtitle_mode] || :soft).to_sym
        )

        Jellyfin::Encoding::EncodingHelper.command_line_arguments(
          info,
          playlist_path: job.playlist_path,
          segment_template: job.segment_template,
          start_segment: job.start_segment,
          capabilities: Jellyfin::MediaEncoder::Encoder.capabilities
        )
      end

      # Mirrors upstream MediaBrowser.Model/Dlna/StreamBuilder.cs:1104-1119:
      # when the request only carries `max_bitrate` (the total streaming
      # cap from the client's DeviceProfile), derive the video bitrate by
      # subtracting audio_bitrate. The port previously hardcoded 2_000_000
      # whenever `video_bitrate` wasn't explicitly set — fine for 1080p,
      # disastrous for 4K HDR (1080p clients saw clearly pixelated output
      # capped at 2 Mbps regardless of what DeviceProfile asked for).
      # 64_000 floor matches upstream's clamp.
      def resolve_video_bitrate(params, source = nil)
        return params[:video_bitrate].to_i if params[:video_bitrate]
        max = params[:max_bitrate]&.to_i
        return 2_000_000 unless max && max.positive?
        audio = (params[:audio_bitrate] || 128_000).to_i
        cap_after_audio = [ max - audio, 64_000 ].max

        # Clamp by the source's video bitrate. Mirrors upstream
        # StreamBuilder.cs:1117 — `Math.Min(availableBitrateForVideo, currentValue)`
        # where currentValue defaults to the source's BitRate. Transcoding
        # to a higher bitrate than the source can't restore quality — it
        # just wastes the encoder. With Caramba's DeviceProfile sending
        # MaxStaticBitrate=1_000_000_000 (1 Gbps), the previous code asked
        # h264_videotoolbox for ~1 Gbps output, which the encoder couldn't
        # keep up with and the throttler perpetually paused it.
        if source && (src_bitrate = source_video_bitrate(source))
          return [ cap_after_audio, src_bitrate ].min
        end
        cap_after_audio
      end

      def source_video_bitrate(source)
        stream = source.default_video_stream
        return nil unless stream
        return stream.bit_rate if stream.bit_rate && stream.bit_rate.positive?
        # Source-level bit_rate falls back to the container's effective
        # rate when the per-stream rate isn't carried in the metadata
        # (common for MKV remuxes from Blu-ray).
        source.effective_bit_rate
      end

      # Maps the request-level Batch-J knobs from job.params onto a fresh
      # EncodingOptions so EncodingHelper picks them up. The mapping mirrors
      # StreamingRequestDto → EncodingOptions in upstream Jellyfin's
      # StreamingHelpers.GetStreamingState.
      def build_encoding_options(job)
        opts = Jellyfin::Encoding::EncodingOptions.new
        # Carry the server-wide hwaccel config into the per-job options.
        # Upstream Jellyfin reads `EncodingOptions.HardwareAccelerationType`
        # plus `EnableHardwareEncoding`; both have to be set, otherwise
        # `EncodingOptions#hardware_acceleration?` returns false and
        # EncodingHelper falls back to libx264/libx265 software. Without
        # this wiring, `Jellyfin::Rails.configuration.hwaccel = :videotoolbox`
        # was a no-op — every transcode pegged the CPU at 900 %+.
        configured = Jellyfin::Rails.configuration.hwaccel
        if configured && configured != :none
          opts.hardware_acceleration_type = configured.to_sym
          opts.enable_hardware_encoding = true
        end
        p = job.params
        opts.auto_crop            = p[:auto_crop]            if p.key?(:auto_crop)
        opts.two_pass             = p[:two_pass]             if p.key?(:two_pass)
        opts.frame_interpolation  = p[:frame_interpolation]  if p.key?(:frame_interpolation)
        opts.target_framerate     = p[:target_framerate]     if p.key?(:target_framerate)
        opts.multi_audio_tracks   = p[:multi_audio_tracks]   if p.key?(:multi_audio_tracks)
        opts.force_accurate_seek  = p[:force_accurate_seek]  if p.key?(:force_accurate_seek)
        opts.enable_loudnorm      = p[:enable_loudnorm]      if p.key?(:enable_loudnorm)
        opts.enable_drc           = p[:enable_drc]           if p.key?(:enable_drc)
        opts.http_user_agent      = p[:http_user_agent]      if p.key?(:http_user_agent)
        opts.http_headers         = p[:http_headers]         if p.key?(:http_headers)
        opts.concat_parts         = p[:concat_parts]         if p.key?(:concat_parts)
        # HLS encryption: when the request asked for it, mint a fresh per-job
        # key + key-info file. Player fetches the key via /keys/:token/...
        if p[:hls_encryption]
          key_uri = build_key_uri(job)
          opts.hls_encryption_material = Jellyfin::Output::HlsEncryption.generate!(
            session_dir: job.dir, key_uri: key_uri
          )
        end
        opts
      end

      def build_key_uri(job)
        # Players need an absolute URL OR a relative-to-playlist URL. Relative
        # is robust to proxying and matches upstream's behaviour for HLS keys.
        # The fingerprint segment is the first 16 hex chars of the key path
        # SHA1 — second factor against URL guessing.
        fp = Digest::SHA1.hexdigest(job.id)[0, 16]
        "../../keys/#{job.id}/#{fp}.key"
      end

      def legacy_args(job)
        ArgsBuilder.new(job.params).call(
          playlist_path: job.playlist_path,
          segment_template: job.segment_template
        )
      end

      # Resolves the -ss offset (in 100-ns ticks) for ffmpeg. A restart at a
      # later segment overrides any caller-supplied start_time_ticks because the
      # restart is what the active client needs to see.
      def seek_ticks_for(job)
        if job.start_segment.positive?
          (job.seek_seconds_for(job.start_segment) * 10_000_000).to_i
        else
          job.params[:start_time_ticks]&.to_i
        end
      end

      def encoder_target(requested, default)
        return default if requested.nil? || requested.empty?
        requested
      end

      def select_video_stream(source, idx)
        return source.default_video_stream if idx.nil?
        source.video_streams[idx.to_i] || source.default_video_stream
      end

      def select_audio_stream(source, idx)
        return source.default_audio_stream if idx.nil?
        source.audio_streams[idx.to_i] || source.default_audio_stream
      end

      def select_subtitle_stream(source, idx)
        return nil if idx.nil?
        source.subtitle_streams[idx.to_i]
      end

      def ensure_reaper!
        return if @reaper&.alive?
        @reaper = Thread.new do
          loop do
            sleep 10
            begin
              reap_idle
            rescue StandardError
              # Don't kill the reaper on unexpected errors.
            end
          end
        end
      end
    end
  end
end
