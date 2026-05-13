require "rbconfig"

# Resolve the bundled jellyfin-ffmpeg binary for the current host. The
# binaries are downloaded by `server/bin/setup-ffmpeg` into
# `server/vendor/ffmpeg/<platform>-<arch>/` — Caramba intentionally does
# NOT fall back to system ffmpeg; jellyfin-ffmpeg's HDR/tonemap/HW-accel
# patches are part of the transcoding contract.
def bundled_ffmpeg_dir
  os = RbConfig::CONFIG["host_os"]
  arch = RbConfig::CONFIG["host_cpu"]

  dir_name =
    case os
    when /darwin/
      case arch
      when /x86_64|amd64/ then "darwin-x64"
      when /arm64|aarch64/ then "darwin-arm64"
      end
    when /linux/
      case arch
      when /x86_64|amd64/ then "linux-x64"
      when /aarch64|arm64/ then "linux-arm64"
      end
    when /mingw|mswin|cygwin/
      case arch
      when /x86_64|amd64/ then "win-x64"
      when /aarch64|arm64/ then "win-arm64"
      end
    end

  return nil unless dir_name
  Rails.root.join("vendor/ffmpeg/#{dir_name}")
end

Rails.application.config.after_initialize do
  bundled = bundled_ffmpeg_dir
  ffmpeg  = ENV["FFMPEG_PATH"]  || (bundled && bundled.join("ffmpeg").to_s)
  ffprobe = ENV["FFPROBE_PATH"] || (bundled && bundled.join("ffprobe").to_s)

  if ffmpeg.nil? || !File.executable?(ffmpeg)
    Rails.logger.warn(
      "[Jellyfin] jellyfin-ffmpeg not found at #{ffmpeg.inspect}. " \
      "Run `server/bin/setup-ffmpeg` to install it for your platform."
    )
  end

  Jellyfin::Rails.configure do |c|
    c.ffmpeg_path  = ffmpeg  if ffmpeg
    c.ffprobe_path = ffprobe if ffprobe
    c.transcode_dir = Rails.root.join("tmp/transcodes")
    c.token_secret  = ENV.fetch("CARAMBA_TOKEN_SECRET") { Rails.application.secret_key_base }
    c.allowed_paths = MediaFolder.enabled.pluck(:path)
    c.hwaccel = :videotoolbox
    c.segment_length = 6
    # 60s matches upstream Jellyfin's PingTimeout for HLS jobs
    # (TranscodeManager.cs:157). The reaper kills any job whose last
    # served segment is older than this — that's our client-disconnect
    # heuristic since the Rails port doesn't hook into HTTP response-end
    # events. Effect: when hls.js stops fetching (paused / tab closed /
    # crashed / forgot to call /stop), ffmpeg dies within ~60-70s.
    c.idle_timeout = 60
  end
rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
  # Migrations haven't run yet — allow rails db:setup / db:create to proceed.
  Jellyfin::Rails.configure { |c| c.allowed_paths = [] }
end
