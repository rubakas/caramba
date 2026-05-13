require 'jellyfin/transcoding/token'
require 'jellyfin/transcoding/transcode_manager'
require 'jellyfin/transcoding/abr_orchestrator'

module Jellyfin
  # GET /transcode/:token/abr_master.m3u8 — multi-rung HLS master playlist.
  #
  # POST a `/playback_info` request first to negotiate; this endpoint then
  # fans out N parallel transcodes (one per ladder rung) and emits a master
  # playlist that references each variant's playlist.
  class AbrController < ApplicationController
    def master
      payload = Jellyfin::Transcoding::Token.decode(params[:token])
      parent_id = derive_parent_id(params[:token])
      parent = manager.ensure_started(id: parent_id, params: payload)

      orchestrator = Jellyfin::Transcoding::AbrOrchestrator.new(
        parent_job: parent, manager: manager
      )
      orchestrator.start! unless File.exist?(orchestrator.master_path)
      wait_for(orchestrator.master_path)

      send_file orchestrator.master_path,
                type: 'application/vnd.apple.mpegurl', disposition: 'inline'
    rescue Jellyfin::Transcoding::Token::InvalidToken => e
      render json: { error: e.message }, status: :bad_request
    end

    private

    def manager
      Jellyfin::Transcoding::TranscodeManager.instance
    end

    def derive_parent_id(token)
      "abr-#{Digest::SHA1.hexdigest(token)[0, 16]}"
    end

    def wait_for(path, timeout: 10)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until File.exist?(path) && File.size(path) > 0
        return if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.05
      end
    end
  end
end
