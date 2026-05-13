require 'jellyfin/transcoding/transcode_manager'

module Jellyfin
  # GET /keys/:token/:fingerprint.key
  #
  # Serves the raw 16-byte AES-128 key for an HLS-encrypted session.
  #
  # The `token` path parameter is actually the JOB ID (matches the segment
  # routes' `derive_job_id` convention). The `fingerprint` segment is a
  # SHA1 prefix of the job ID — a second factor that prevents trivial URL
  # forgery from a leaked job ID alone.
  class KeysController < ApplicationController
    def show
      job_id = params[:token]
      expected_fp = Digest::SHA1.hexdigest(job_id)[0, 16]
      return head(:not_found) unless ActiveSupport::SecurityUtils.secure_compare(
        params[:fingerprint].to_s, expected_fp
      )
      job = Jellyfin::Transcoding::TranscodeManager.instance.find(job_id)
      return head(:not_found) unless job

      key_path = File.join(job.dir, 'enc.key')
      return head(:not_found) unless File.exist?(key_path)

      bytes = Jellyfin::Output::HlsEncryption.read_key(key_path)
      send_data bytes, type: 'application/octet-stream', disposition: 'inline'
    end
  end
end
