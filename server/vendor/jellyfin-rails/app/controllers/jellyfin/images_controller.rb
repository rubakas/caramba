require 'jellyfin/transcoding/token'
require 'jellyfin/images/extractor'

module Jellyfin
  # GET /images/:token/:type
  #
  # Serves item artwork. Resolution order:
  #   1. Sidecar (poster.jpg / fanart.jpg / etc. alongside the media file)
  #   2. Embedded attached_pic (cover art in MKV/FLAC)
  #   3. Generated chapter thumb when type=chapter and start_time is given
  class ImagesController < ApplicationController
    def show
      payload = Jellyfin::Transcoding::Token.decode(params[:token])
      media = payload[:path].to_s
      type = params[:type].to_s.downcase.to_sym

      unless Jellyfin::Rails.configuration.path_allowed?(media)
        return render json: { error: 'path not allowed' }, status: :forbidden
      end
      unless File.exist?(media)
        return render json: { error: 'file not found' }, status: :not_found
      end

      file = resolve_image(media, type)
      return head(:not_found) unless file && File.exist?(file)
      send_file file, type: mime_for(file), disposition: 'inline'
    rescue Jellyfin::Transcoding::Token::InvalidToken => e
      render json: { error: e.message }, status: :bad_request
    end

    private

    def resolve_image(media, type)
      extractor = Jellyfin::Images::Extractor.new(
        ffmpeg_path: Jellyfin::Rails.configuration.ffmpeg_path,
        cache_root: Jellyfin::Rails.configuration.resolved_transcode_dir.to_s
      )
      case type
      when :primary, :backdrop, :logo, :banner, :art
        sidecar = extractor.sidecar(media_path: media, type: type)
        return sidecar if sidecar
        extractor.embedded_cover(media_path: media) if type == :primary
      when :chapter
        return nil unless params[:start_time]
        extractor.chapter_thumbnail(
          media_path: media,
          start_time_seconds: params[:start_time].to_f,
          width: (params[:width] || 320).to_i
        )
      end
    end

    def mime_for(file)
      case File.extname(file).downcase
      when '.png' then 'image/png'
      when '.webp' then 'image/webp'
      else             'image/jpeg'
      end
    end
  end
end
