require 'jellyfin/transcoding/token'
require 'jellyfin/transcoding/transcode_manager'

module Jellyfin
  # Port of DynamicHlsController.GetLiveHlsStream (cs:168). Serves a
  # sliding-window HLS playlist for live sources (rtsp, rtmp, udp, srt …)
  # that LiveStreamRegistry has tunneled.
  #
  #   GET /live_hls/:token/live.m3u8
  #
  # Unlike the VOD `/transcode/:token/master.m3u8`, this playlist:
  #   - has `EXT-X-PLAYLIST-TYPE:LIVE`
  #   - omits `EXT-X-ENDLIST` while the stream continues
  #   - lists only the last N segments
  class LiveHlsController < ApplicationController
    def show
      payload = Jellyfin::Transcoding::Token.decode(params[:token])
      job = manager.ensure_started(
        id: "live-#{Digest::SHA1.hexdigest(params[:token])[0, 16]}",
        params: payload.merge(live: true)
      )
      job.ping!
      wait_for_playlist!(job)
      # ffmpeg already writes the live-style playlist when `-hls_playlist_type
      # live` is set (see Encoding::EncodingHelper#live_segmented?). We serve
      # whatever ffmpeg has produced so the sliding window is up to date.
      return head(:gateway_timeout) unless File.exist?(job.playlist_path)
      send_file job.playlist_path,
                type: 'application/vnd.apple.mpegurl', disposition: 'inline'
    rescue Jellyfin::Transcoding::Token::InvalidToken => e
      render json: { error: e.message }, status: :bad_request
    rescue ActionController::MissingFile
      head :gateway_timeout
    end

    private

    def manager = Jellyfin::Transcoding::TranscodeManager.instance

    def wait_for_playlist!(job, timeout: 15)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until File.exist?(job.playlist_path) && File.size(job.playlist_path) > 0
        return if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.05
      end
    end
  end
end
