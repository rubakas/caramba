Rails.application.config.after_initialize do
  Jellyfin::Rails.configure do |c|
    c.ffmpeg_path  = ENV.fetch("FFMPEG_PATH",  "ffmpeg")
    c.ffprobe_path = ENV.fetch("FFPROBE_PATH", "ffprobe")
    c.transcode_dir = Rails.root.join("tmp/transcodes")
    c.token_secret  = ENV.fetch("CARAMBA_TOKEN_SECRET") { Rails.application.secret_key_base }
    c.allowed_paths = MediaFolder.enabled.pluck(:path)
    c.hwaccel = :videotoolbox
    c.segment_length = 6
    c.idle_timeout = 15 * 60
  end
rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
  # Migrations haven't run yet — allow rails db:setup / db:create to proceed.
  Jellyfin::Rails.configure { |c| c.allowed_paths = [] }
end
