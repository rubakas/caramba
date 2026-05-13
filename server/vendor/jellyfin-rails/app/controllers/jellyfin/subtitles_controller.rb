require 'open3'
require 'fileutils'
require 'jellyfin/transcoding/token'
require 'jellyfin/media_encoder/probe'
require 'jellyfin/subtitle/converter'

module Jellyfin
  # Extracts embedded subtitle streams as WebVTT on demand. Mirrors the role of
  # /Videos/{itemId}/{mediaSourceId}/Subtitles/{index}/Stream.{format} upstream.
  #
  # Output is cached on disk keyed by [path, mtime, stream index, output format].
  class SubtitlesController < ApplicationController
    SUPPORTED_FORMATS = %w[vtt srt ass].freeze

    # GET /jellyfin/subtitles/:token/:index.:format
    # Token must be a regular transcode token (or a dedicated subtitle token in the future).
    def show
      payload = Jellyfin::Transcoding::Token.decode(params[:token])
      path = payload[:path].to_s

      unless Jellyfin::Rails.configuration.path_allowed?(path)
        return render json: { error: 'path not allowed' }, status: :forbidden
      end
      unless File.exist?(path)
        return render json: { error: 'file not found' }, status: :not_found
      end

      index = Integer(params[:index])
      format = params[:format].to_s.downcase
      return render(json: { error: 'unsupported format' }, status: :unprocessable_entity) unless SUPPORTED_FORMATS.include?(format)

      cache_path = cache_path_for(path, index, format)
      extract_to(cache_path, path, index, format) unless File.exist?(cache_path)
      send_file cache_path, type: mime_for(format), disposition: 'inline'
    rescue Jellyfin::Transcoding::Token::InvalidToken => e
      render json: { error: e.message }, status: :bad_request
    rescue ArgumentError, TypeError
      render json: { error: 'bad index' }, status: :bad_request
    end

    # GET /jellyfin/subtitles/:token/:index/:start_position_ticks.:format
    #
    # Port of SubtitleController.GetSubtitleWithTicks (SubtitleController.cs:298).
    # Same extraction as `#show` but additionally filters cues by start position
    # (and optional ?end_position_ticks=...) using SubtitleEncoder.FilterEvents.
    def with_ticks
      payload = Jellyfin::Transcoding::Token.decode(params[:token])
      path = payload[:path].to_s
      return render(json: { error: 'path not allowed' }, status: :forbidden) unless Jellyfin::Rails.configuration.path_allowed?(path)
      return render(json: { error: 'file not found' }, status: :not_found) unless File.exist?(path)

      index = Integer(params[:index])
      format = params[:format].to_s.downcase
      return render(json: { error: 'unsupported format' }, status: :unprocessable_entity) unless SUPPORTED_FORMATS.include?(format)

      start_ticks = params[:start_position_ticks].to_i
      end_ticks = params[:end_position_ticks].to_i
      preserve = ['true', '1', true, 1].include?(params[:preserve_original_timestamps])

      # First extract the full subtitle, then filter via Converter.
      cache_path = cache_path_for(path, index, format)
      extract_to(cache_path, path, index, format) unless File.exist?(cache_path)
      converted = Jellyfin::Subtitle::Converter.convert(
        text: File.read(cache_path),
        input_format: format, output_format: format,
        start_time_ticks: start_ticks, end_time_ticks: end_ticks,
        preserve_original_timestamps: preserve
      )
      render plain: converted, content_type: mime_for(format)
    rescue Jellyfin::Transcoding::Token::InvalidToken => e
      render json: { error: e.message }, status: :bad_request
    rescue RuntimeError => e
      # ffmpeg failure (missing subtitle stream, codec issue) → 502 per upstream.
      render json: { error: e.message }, status: :bad_gateway
    end

    private

    def cache_path_for(path, index, format)
      stat = File.stat(path)
      dir = File.join(Jellyfin::Rails.configuration.resolved_transcode_dir.to_s, 'subs')
      FileUtils.mkdir_p(dir)
      key = Digest::SHA1.hexdigest([path, stat.mtime.to_i, stat.size, index, format].join('|'))[0, 16]
      File.join(dir, "#{key}.#{format}")
    end

    def extract_to(out_path, src_path, index, format)
      ffmpeg = Jellyfin::Rails.configuration.ffmpeg_path
      _out, err, status = Open3.capture3(
        ffmpeg, '-y', '-hide_banner', '-loglevel', 'warning',
        '-i', src_path, '-map', "0:s:#{index}", '-c:s', codec_for(format), out_path
      )
      raise "ffmpeg subtitle extract failed: #{err.strip}" unless status.success?
    end

    def codec_for(format)
      case format
      when 'vtt' then 'webvtt'
      when 'srt' then 'srt'
      when 'ass' then 'ass'
      end
    end

    def mime_for(format)
      case format
      when 'vtt' then 'text/vtt'
      when 'srt' then 'application/x-subrip'
      when 'ass' then 'text/x-ssa'
      end
    end
  end
end
