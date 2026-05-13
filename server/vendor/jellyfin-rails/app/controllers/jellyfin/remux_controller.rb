require 'open3'
require 'jellyfin/transcoding/token'
require 'jellyfin/playback/remux_args'

module Jellyfin
  # GET /stream/:token/remux.:container
  #
  # Spawns `ffmpeg -c copy` to rewrite the container without re-encoding the
  # video / audio bitstreams. Used when the source codecs are compatible with
  # the client but the source container isn't (mkv → mp4, ts → mp4, etc.).
  #
  # Streams via Ruby chunked transfer so the client can start playing while
  # the remux is still running. Range requests are NOT supported in this mode
  # — clients that need seek should use direct-play or HLS.
  class RemuxController < ApplicationController
    SUPPORTED = %w[mp4 mkv webm ts].freeze

    def show
      payload = Jellyfin::Transcoding::Token.decode(params[:token])
      source_path = payload[:path].to_s
      container = params[:container].to_s.downcase

      unless Jellyfin::Rails.configuration.path_allowed?(source_path)
        return render json: { error: 'path not allowed' }, status: :forbidden
      end
      unless File.exist?(source_path)
        return render json: { error: 'file not found' }, status: :not_found
      end
      unless SUPPORTED.include?(container)
        return render json: { error: "unsupported remux target: #{container}" }, status: :unprocessable_entity
      end

      args = Jellyfin::Playback::RemuxArgs.call(
        source_path: source_path,
        output_path: 'pipe:1',
        target_container: container,
        video_track: payload[:video_track].to_i,
        audio_track: payload[:audio_track].to_i,
        fast_start: container == 'mp4'
      )
      cmd = [Jellyfin::Rails.configuration.ffmpeg_path, *args]

      response.headers['Content-Type'] = content_type_for(container)
      response.headers['Cache-Control'] = 'no-cache'
      response.headers['X-Accel-Buffering'] = 'no' # disable nginx buffering when proxied
      self.response_body = Enumerator.new do |yielder|
        IO.popen(cmd, 'rb') do |io|
          while (chunk = io.read(64 * 1024))
            yielder << chunk
          end
        end
      end
    rescue Jellyfin::Transcoding::Token::InvalidToken => e
      render json: { error: e.message }, status: :bad_request
    end

    private

    def content_type_for(container)
      case container
      when 'mp4'  then 'video/mp4'
      when 'mkv'  then 'video/x-matroska'
      when 'webm' then 'video/webm'
      when 'ts'   then 'video/mp2t'
      end
    end
  end
end
