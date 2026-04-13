# Separate controller for streaming endpoints that require ActionController::Live.
# This keeps Live isolated from regular PlaybackController actions which use
# standard render calls that don't work well with Live.
class Api::PlaybackStreamController < Api::BaseController
  include ActionController::Live

  # GET /api/playback/stream/:session_id
  #
  # Pipes ffmpeg's fragmented MP4 stdout directly to the HTTP response.
  # This mirrors the desktop Electron stream:// protocol handler.
  # The browser's <video> element can play fMP4 natively.
  def stream
    session_id = params[:session_id]

    unless TranscoderService.active?(session_id)
      response.headers["Content-Type"] = "text/plain"
      response.stream.write "Session not found"
      response.stream.close
      return
    end

    io = TranscoderService.stream_io
    unless io
      response.headers["Content-Type"] = "text/plain"
      response.stream.write "No active stream"
      response.stream.close
      return
    end

    response.headers["Content-Type"] = "video/mp4"
    response.headers["Cache-Control"] = "no-cache, no-store"
    response.headers["X-Accel-Buffering"] = "no"  # disable nginx buffering if proxied
    response.headers["Last-Modified"] = Time.now.httpdate  # prevent Rack::ConditionalGet buffering
    response.headers["ETag"] = nil  # prevent Rack::ETag buffering

    # Pipe ffmpeg stdout → HTTP response in 64KB chunks.
    # Force binary encoding so Rack/Puma don't attempt any re-encoding.
    begin
      while (chunk = io.read(65_536))
        response.stream.write(chunk)
      end
    rescue IOError, Errno::EPIPE, ActionController::Live::ClientDisconnected => e
      Rails.logger.debug "[Stream] client disconnected or pipe closed: #{e.class}"
    ensure
      response.stream.close
    end
  end
end
