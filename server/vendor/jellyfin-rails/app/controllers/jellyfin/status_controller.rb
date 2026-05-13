require 'jellyfin/media_encoder/encoder'

module Jellyfin
  class StatusController < ApplicationController
    def show
      caps = Jellyfin::MediaEncoder::Encoder.capabilities
      render json: {
        gem_version: Jellyfin::Rails::VERSION,
        ffmpeg_path: Jellyfin::Rails.configuration.ffmpeg_path,
        ffmpeg: caps.to_h_summary
      }
    end
  end
end
