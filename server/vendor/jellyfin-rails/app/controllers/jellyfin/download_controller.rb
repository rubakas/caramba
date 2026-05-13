require 'jellyfin/transcoding/token'

module Jellyfin
  # GET /download/:token
  #
  # Single-file delivery with Content-Disposition: attachment so the browser
  # offers a Save dialog. Mirrors LibraryController.GetDownload.
  class DownloadController < ApplicationController
    def show
      payload = Jellyfin::Transcoding::Token.decode(params[:token])
      path = payload[:path].to_s

      unless Jellyfin::Rails.configuration.path_allowed?(path)
        return render json: { error: 'path not allowed' }, status: :forbidden
      end
      unless File.exist?(path)
        return render json: { error: 'file not found' }, status: :not_found
      end

      filename = File.basename(path)
      send_file path, type: 'application/octet-stream',
                disposition: %(attachment; filename="#{filename.gsub('"', '')}")
    rescue Jellyfin::Transcoding::Token::InvalidToken => e
      render json: { error: e.message }, status: :bad_request
    end
  end
end
