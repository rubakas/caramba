require 'jellyfin/media_encoder/probe'

module Jellyfin
  class ProbeController < ApplicationController
    def show
      path = params.require(:path)

      unless Jellyfin::Rails.configuration.path_allowed?(path)
        return render json: { error: 'path not allowed' }, status: :forbidden
      end

      unless File.exist?(path)
        return render json: { error: 'file not found' }, status: :not_found
      end

      info = Jellyfin::MediaEncoder::Probe.from_path(path)
      render json: info.to_h
    rescue Jellyfin::MediaEncoder::Probe::ProbeFailed => e
      render json: { error: 'probe failed', detail: e.message }, status: :unprocessable_entity
    end
  end
end
