require 'jellyfin/transcoding/token'
require 'jellyfin/media_encoder/probe'

module Jellyfin
  # GET /audio/:token/universal.:container
  #
  # Mirrors UniversalAudioController.cs: depending on the requested container
  # we either direct-play (when container matches the source) or transcode.
  # We support mp3/aac/flac/opus targets.
  class UniversalAudioController < ApplicationController
    DIRECT_PLAYABLE = { 'mp3' => 'audio/mpeg', 'aac' => 'audio/aac',
                        'flac' => 'audio/flac', 'm4a' => 'audio/mp4',
                        'opus' => 'audio/opus', 'ogg' => 'audio/ogg' }.freeze

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

      source = Jellyfin::MediaEncoder::Probe.from_path(source_path)
      source_container = source.container.to_s.downcase

      if source_container == container && DIRECT_PLAYABLE.key?(container)
        # Same container as source — direct play.
        response.headers['Accept-Ranges'] = 'bytes'
        return send_file(source_path, type: DIRECT_PLAYABLE.fetch(container), disposition: 'inline')
      end

      # Transcode-on-the-fly. We pipe ffmpeg output via send_data with a Rack
      # streaming body. Production deployments would route this through nginx
      # but for the SDK we use Ruby's Open3.
      stream_transcoded(source_path, container)
    rescue Jellyfin::Transcoding::Token::InvalidToken => e
      render json: { error: e.message }, status: :bad_request
    end

    private

    def stream_transcoded(source_path, container)
      codec_args =
        case container
        when 'mp3'  then ['-c:a', 'libmp3lame', '-b:a', '192k']
        when 'aac', 'm4a' then ['-c:a', 'aac', '-b:a', '192k']
        when 'flac' then ['-c:a', 'flac']
        when 'opus', 'ogg' then ['-c:a', 'libopus', '-b:a', '128k']
        else
          return render(json: { error: "unsupported container: #{container}" }, status: :unprocessable_entity)
        end

      ff_format = container == 'm4a' ? 'ipod' : container
      cmd = [Jellyfin::Rails.configuration.ffmpeg_path,
             '-hide_banner', '-loglevel', 'error',
             '-i', source_path, '-vn'] + codec_args + ['-f', ff_format, 'pipe:1']

      response.headers['Content-Type'] = DIRECT_PLAYABLE.fetch(container, 'application/octet-stream')
      response.headers['Cache-Control'] = 'no-cache'
      self.response_body = Enumerator.new do |yielder|
        IO.popen(cmd, 'rb') do |io|
          while (chunk = io.read(64 * 1024))
            yielder << chunk
          end
        end
      end
    end
  end
end
