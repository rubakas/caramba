require 'jellyfin/transcoding/transcode_manager'

module Jellyfin
  # GET /transcode/:token/progress — current ffmpeg progress for a job.
  #
  # Returns parsed `-progress` pipe data: frame, fps, bitrate, out_time_ms,
  # speed, dup/drop frames. Empty {} when the job has no progress reader yet.
  class ProgressController < ApplicationController
    def show
      job_id = derive_job_id(params[:token])
      job = Jellyfin::Transcoding::TranscodeManager.instance.find(job_id)
      return render(json: { error: 'unknown job' }, status: :not_found) unless job
      render json: job.progress_snapshot
    end

    private

    def derive_job_id(token)
      Digest::SHA1.hexdigest(token)[0, 16]
    end
  end
end
