require 'jellyfin/transcoding/transcode_manager'

module Jellyfin
  # Port of HlsSegmentController.StopEncodingProcess (cs:109).
  #
  # DELETE /videos/active_encodings?play_session_id=... [&device_id=...]
  #
  # Upstream calls `KillTranscodingJobs(deviceId, playSessionId, _ => true)`
  # which finds every active job matching the (device_id, play_session_id)
  # tuple and tears them down. We don't track device_id (no user/session model)
  # so play_session_id is the primary identifier; device_id is accepted for
  # API compatibility but ignored.
  class ActiveEncodingsController < ApplicationController
    def destroy
      session_id = params[:play_session_id].to_s
      return unprocessable('play_session_id is required') if session_id.empty?

      killed = 0
      manager = Jellyfin::Transcoding::TranscodeManager.instance
      manager.instance_variable_get(:@jobs)&.values&.dup&.each do |job|
        next unless job.play_session_id == session_id
        manager.cancel!(job.id)
        killed += 1
      end
      head :no_content
    end

    private

    def unprocessable(msg)
      render json: { error: msg }, status: :unprocessable_entity
    end
  end
end
