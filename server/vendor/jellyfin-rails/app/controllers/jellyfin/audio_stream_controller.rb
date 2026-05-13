require 'jellyfin/transcoding/token'
require 'jellyfin/media_encoder/probe'
require 'jellyfin/encoding/progressive_audio'

module Jellyfin
  # Progressive audio streaming. Ports AudioController.cs from upstream:
  #
  #   GET/HEAD /Audio/{itemId}/stream
  #   GET/HEAD /Audio/{itemId}/stream.{container}
  #
  # Our route shape:
  #
  #   GET/HEAD /audio_stream/:token/stream
  #   GET/HEAD /audio_stream/:token/stream.:container
  #
  # Distinct from the existing `/audio/:token/universal.{container}` endpoint
  # (UniversalAudioController) — the universal path does direct-play when
  # possible. This endpoint ALWAYS transcodes through the progressive arg
  # builder, which is what upstream `/Audio/{id}/stream` does.
  class AudioStreamController < ApplicationController
    SUPPORTED = %w[mp3 aac flac m4a opus ogg wav].freeze
    DEFAULT_CONTAINER = 'mp3'.freeze

    def stream
      payload = Jellyfin::Transcoding::Token.decode(params[:token])
      source_path = payload[:path].to_s
      container = (params[:container] || DEFAULT_CONTAINER).to_s.downcase

      return forbid('path not allowed') unless Jellyfin::Rails.configuration.path_allowed?(source_path)
      return not_found('file not found') unless File.exist?(source_path)
      return unprocessable("unsupported container: #{container}") unless SUPPORTED.include?(container)

      if request.head?
        response.headers['Content-Type'] = content_type_for(container)
        return head(:ok)
      end

      job_info = build_job_info(source_path, container, payload)
      args = Jellyfin::Encoding::ProgressiveAudio.command_line(
        job: job_info, output_path: 'pipe:1',
        capabilities: Jellyfin::MediaEncoder::Encoder.capabilities
      )
      # ProgressiveAudio doesn't know the muxer name; supply it.
      args = inject_output_format(args, container)
      cmd = [Jellyfin::Rails.configuration.ffmpeg_path, *args]

      response.headers['Content-Type'] = content_type_for(container)
      response.headers['Cache-Control'] = 'no-cache'
      response.headers['X-Accel-Buffering'] = 'no'
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

    def build_job_info(source_path, container, payload)
      source = Jellyfin::MediaEncoder::Probe.from_path(source_path)
      opts = Jellyfin::Encoding::EncodingOptions.new
      Jellyfin::Encoding::EncodingJobInfo.new(
        media_source: source, options: opts,
        output_audio_codec: encoder_for(container),
        output_audio_bitrate: (payload[:audio_bitrate] || 192_000).to_i,
        output_audio_channels: (payload[:audio_channels] || 2).to_i,
        output_audio_sample_rate: (payload[:audio_sample_rate] || 48_000).to_i,
        audio_stream: source.default_audio_stream
      )
    end

    def encoder_for(container)
      case container
      when 'mp3'           then 'mp3'
      when 'aac', 'm4a'    then 'aac'
      when 'flac'          then 'flac'
      when 'opus', 'ogg'   then 'opus'
      when 'wav'           then 'pcm_s16le'
      end
    end

    def inject_output_format(args, container)
      # Some containers have a different muxer name than the codec hint.
      muxer =
        case container
        when 'm4a' then 'ipod'
        when 'ogg' then 'ogg'
        else container
        end
      # ProgressiveAudio always ends with -y output_path; inject -f before it.
      idx = args.index('-y')
      return args + ['-f', muxer] unless idx
      args.dup.tap { |a| a.insert(idx, '-f', muxer) }
    end

    def content_type_for(container)
      case container
      when 'mp3'  then 'audio/mpeg'
      when 'aac'  then 'audio/aac'
      when 'flac' then 'audio/flac'
      when 'm4a'  then 'audio/mp4'
      when 'opus', 'ogg' then 'audio/ogg'
      when 'wav'  then 'audio/wav'
      end
    end

    def forbid(msg)        = render(json: { error: msg }, status: :forbidden)
    def not_found(msg)     = render(json: { error: msg }, status: :not_found)
    def unprocessable(msg) = render(json: { error: msg }, status: :unprocessable_entity)
  end
end
