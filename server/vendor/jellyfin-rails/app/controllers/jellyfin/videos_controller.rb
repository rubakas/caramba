require 'jellyfin/transcoding/token'
require 'jellyfin/media_encoder/probe'
require 'jellyfin/encoding/progressive_video'

module Jellyfin
  # Progressive video streaming. Ports the corresponding endpoints from
  # upstream `VideosController.cs`:
  #
  #   GET/HEAD /Videos/{itemId}/stream
  #   GET/HEAD /Videos/{itemId}/stream.{container}
  #
  # Our route shape is parallel:
  #
  #   GET/HEAD /videos/:token/stream
  #   GET/HEAD /videos/:token/stream.:container
  #
  # The token contains the path + transcode params (same scheme as our HLS
  # endpoints). The stream is produced by `ProgressiveVideo.command_line` and
  # piped to the client via Rack's chunked Enumerator body.
  class VideosController < ApplicationController
    SUPPORTED = %w[mp4 mkv webm ts].freeze
    DEFAULT_CONTAINER = 'mp4'.freeze

    def stream
      payload = Jellyfin::Transcoding::Token.decode(params[:token])
      source_path = payload[:path].to_s
      container = (params[:container] || DEFAULT_CONTAINER).to_s.downcase

      return forbid('path not allowed') unless Jellyfin::Rails.configuration.path_allowed?(source_path)
      return not_found('file not found') unless File.exist?(source_path)
      return unprocessable("unsupported container: #{container}") unless SUPPORTED.include?(container)

      # HEAD requests probe codec/size before fetch. Upstream returns an empty
      # body with the right Content-Type so the client can decide whether to
      # commit to the full transcode.
      if request.head?
        response.headers['Content-Type'] = content_type_for(container)
        return head(:ok)
      end

      job_info = build_job_info(source_path, container, payload)
      args = Jellyfin::Encoding::ProgressiveVideo.command_line(
        job: job_info, output_path: 'pipe:1',
        capabilities: Jellyfin::MediaEncoder::Encoder.capabilities
      )
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
      Jellyfin::Encoding::EncodingJobInfo.new(
        media_source: source,
        output_video_codec: encoder_target(payload[:video_codec], 'libx264'),
        output_audio_codec: encoder_target(payload[:audio_codec], 'aac'),
        output_video_bitrate: (payload[:video_bitrate] || 2_000_000).to_i,
        output_audio_bitrate: (payload[:audio_bitrate] || 128_000).to_i,
        output_audio_channels: payload[:audio_channels]&.to_i,
        output_height: payload[:max_height]&.to_i,
        start_time_ticks: payload[:start_time_ticks]&.to_i,
        video_stream: source.video_streams[(payload[:video_track] || 0).to_i],
        audio_stream: source.audio_streams[(payload[:audio_track] || 0).to_i],
        subtitle_stream: payload[:subtitle_track] && source.subtitle_streams[payload[:subtitle_track].to_i],
        subtitle_method: (payload[:subtitle_mode] || :soft).to_sym
      )
    end

    def encoder_target(requested, default)
      return default if requested.nil? || requested.to_s.empty?
      requested
    end

    def content_type_for(container)
      case container
      when 'mp4'  then 'video/mp4'
      when 'mkv'  then 'video/x-matroska'
      when 'webm' then 'video/webm'
      when 'ts'   then 'video/mp2t'
      end
    end

    def forbid(msg)       = render(json: { error: msg }, status: :forbidden)
    def not_found(msg)    = render(json: { error: msg }, status: :not_found)
    def unprocessable(msg) = render(json: { error: msg }, status: :unprocessable_entity)
  end
end
