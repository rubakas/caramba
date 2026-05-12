# Clean up any lingering ffmpeg transcoding sessions on server shutdown.
at_exit do
  TranscoderService.stop_all
rescue => e
  Rails.logger.warn "[Transcoder] cleanup error: #{e.message}"
end

# Kill stray ffmpeg children that survived a previous Rails crash. We
# only have the previous run's process IDs through pgrep against our
# vendored ffmpeg paths — anything pointing at desktop/vendor/
# (jellyfin-ffmpeg or ffmpeg-arm64) plus the caramba-sessions tmp
# directory is ours to claim. Without this, a NoMethodError-style
# crash leaks ffmpegs that keep encoding and saturate the GPU; the
# next user playback session then sees 0.5x speed instead of 5×.
Rails.application.config.after_initialize do
  begin
    out = `pgrep -fl 'caramba/desktop/vendor/.*ffmpeg.*caramba-sessions' 2>/dev/null`
    out.each_line do |line|
      pid = line.split.first.to_i
      next if pid <= 0
      begin
        Process.kill("KILL", pid)
        Rails.logger.info "[Transcoder] killed stray ffmpeg pid=#{pid} from previous run"
      rescue Errno::ESRCH
        # already gone
      end
    end
  rescue => e
    Rails.logger.warn "[Transcoder] orphan cleanup error: #{e.message}"
  end
end
