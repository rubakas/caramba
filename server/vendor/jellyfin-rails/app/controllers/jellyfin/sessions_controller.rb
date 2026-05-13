require 'jellyfin/session/tracker'

module Jellyfin
  # Playback session lifecycle:
  #
  #   POST /sessions/playing            — client starts playback
  #   POST /sessions/playing/progress   — client reports position (every ~5s)
  #   POST /sessions/playing/stopped    — client ends playback
  #   POST /sessions/playing/ping       — keep-alive without progress update
  #   GET  /sessions/active             — admin view of active sessions
  class SessionsController < ApplicationController
    def playing
      params_hash = playback_params
      Jellyfin::Session::Tracker.instance.started(
        id: params_hash[:session_id],
        item_id: params_hash[:item_id],
        user_id: params_hash[:user_id],
        client: params_hash[:client],
        device: params_hash[:device],
        version: params_hash[:version],
        run_time_ticks: params_hash[:run_time_ticks]&.to_i,
        playback_method: params_hash[:playback_method] || 'direct_play'
      )
      head :no_content
    end

    def progress
      params_hash = playback_params
      sess = Jellyfin::Session::Tracker.instance.progress(
        id: params_hash[:session_id],
        position_ticks: params_hash[:position_ticks]&.to_i || 0,
        paused: params_hash[:paused]
      )
      # Mirrors upstream's flow: every progress checkin is also a
      # PingTranscodingJob, which carries IsUserPaused through to ffmpeg.
      Jellyfin::Transcoding::TranscodeManager.instance.ping_session(
        params_hash[:session_id], is_user_paused: params_hash[:paused]
      )
      sess ? render(json: sess.to_h_serializable) : not_found_session
    end

    def stopped
      sess = Jellyfin::Session::Tracker.instance.stopped(
        id: params[:session_id],
        position_ticks: params[:position_ticks]&.to_i
      )
      sess ? render(json: sess.to_h_serializable) : not_found_session
    end

    def ping
      sess = Jellyfin::Session::Tracker.instance.ping(id: params[:session_id])
      # Mirrors upstream PingTranscodingJob keepalive.
      Jellyfin::Transcoding::TranscodeManager.instance.ping_session(params[:session_id])
      sess ? head(:no_content) : not_found_session
    end

    def active
      render json: {
        count: Jellyfin::Session::Tracker.instance.size,
        sessions: Jellyfin::Session::Tracker.instance.active.map(&:to_h_serializable)
      }
    end

    private

    def playback_params
      params.permit(:session_id, :item_id, :user_id, :client, :device, :version,
                    :run_time_ticks, :position_ticks, :paused, :playback_method)
            .to_h.symbolize_keys
    end

    def not_found_session
      render json: { error: 'unknown session_id' }, status: :not_found
    end
  end
end
