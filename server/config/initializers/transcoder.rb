# Clean up any lingering ffmpeg transcoding sessions on server shutdown.
at_exit do
  TranscoderService.stop_all
rescue => e
  Rails.logger.warn "[Transcoder] cleanup error: #{e.message}"
end
