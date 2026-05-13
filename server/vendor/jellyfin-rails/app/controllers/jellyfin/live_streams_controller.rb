require 'securerandom'
require 'jellyfin/transcoding/live_stream_registry'

module Jellyfin
  # Live-stream session management. A "live stream" is a non-file source the
  # server pulls (rtsp camera, rtmp ingest, udp multicast, srt feed). Multiple
  # concurrent transcodes can share the same upstream pull via refcount in
  # LiveStreamRegistry; the registry closes the underlying source when the
  # last consumer drops.
  #
  # Endpoints:
  #   POST   /live_streams/open    body: { url, close_cmd? }
  #   POST   /live_streams/close   body: { id }
  #   GET    /live_streams/active
  class LiveStreamsController < ApplicationController
    ALLOWED_SCHEMES = %w[rtsp rtmp udp srt rtp http https].freeze

    def open
      url = params.require(:url).to_s
      scheme = url.split(':', 2).first.to_s.downcase
      unless ALLOWED_SCHEMES.include?(scheme)
        return render json: { error: "scheme not allowed: #{scheme}" }, status: :unprocessable_entity
      end

      id = SecureRandom.hex(8)
      close_cmd = params[:close_cmd] # optional shell command to invoke on last-drop

      Jellyfin::Transcoding::LiveStreamRegistry.instance.register(
        id, close: build_close_proc(close_cmd)
      )

      render json: { id: id, url: url, refcount: 1 }
    end

    def close
      id = params.require(:id).to_s
      Jellyfin::Transcoding::LiveStreamRegistry.instance.release(id)
      head :no_content
    end

    def active
      registry = Jellyfin::Transcoding::LiveStreamRegistry.instance
      # The registry doesn't expose its keys directly; mirror via reflection.
      streams = registry.instance_variable_get(:@streams) || {}
      render json: {
        count: streams.size,
        streams: streams.map { |id, e| { id: id, refcount: e[:count] } }
      }
    end

    private

    def build_close_proc(close_cmd)
      return -> { } if close_cmd.nil? || close_cmd.empty?
      lambda do
        system(close_cmd) # best-effort; never raise
      rescue StandardError
        nil
      end
    end
  end
end
