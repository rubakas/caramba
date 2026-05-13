require 'jellyfin/transcoding/token'

module Jellyfin
  # Direct play endpoint: serves the source file directly with HTTP Range
  # support. Rails' send_file handles Range natively when X-Sendfile / nginx
  # aren't configured, but we still surface Accept-Ranges so clients use it.
  class StreamController < ApplicationController
    def show
      payload = Jellyfin::Transcoding::Token.decode(params[:token])
      path = payload[:path].to_s

      unless Jellyfin::Rails.configuration.path_allowed?(path)
        return render json: { error: 'path not allowed' }, status: :forbidden
      end
      unless File.exist?(path)
        return render json: { error: 'file not found' }, status: :not_found
      end

      response.headers['Accept-Ranges'] = 'bytes'
      send_file path, disposition: 'inline', type: content_type_for(path),
                stream: true, buffer_size: 1.megabyte rescue
        send_file(path, disposition: 'inline', type: content_type_for(path))
    rescue Jellyfin::Transcoding::Token::InvalidToken => e
      render json: { error: e.message }, status: :bad_request
    end

    private

    def content_type_for(path)
      ext = File.extname(path).delete('.').downcase
      case ext
      when 'mp4', 'm4v' then 'video/mp4'
      when 'mov'        then 'video/quicktime'
      when 'mkv'        then 'video/x-matroska'
      when 'webm'       then 'video/webm'
      when 'ts'         then 'video/mp2t'
      when 'avi'        then 'video/x-msvideo'
      when 'flv'        then 'video/x-flv'
      when 'mp3'        then 'audio/mpeg'
      when 'flac'       then 'audio/flac'
      when 'aac'        then 'audio/aac'
      when 'm4a'        then 'audio/mp4'
      when 'ogg'        then 'audio/ogg'
      when 'wav'        then 'audio/wav'
      else                   'application/octet-stream'
      end
    end
  end
end
