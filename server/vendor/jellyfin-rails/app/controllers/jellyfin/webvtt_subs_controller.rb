require 'jellyfin/transcoding/token'
require 'jellyfin/subtitle/segmenter'

module Jellyfin
  # GET /webvtt/:token/:stream_index/index.m3u8 — per-track playlist
  # GET /webvtt/:token/:stream_index/:segment.vtt — one segment of cues
  class WebvttSubsController < ApplicationController
    DEFAULT_SEGMENT_LENGTH = 6

    def index
      ensure_segmented!
      meta = segmenter_result
      return head(:not_found) unless meta
      render plain: meta[:playlist], content_type: 'application/vnd.apple.mpegurl'
    end

    def segment
      ensure_segmented!
      path = segmenter.segment_path(source_path: source_path,
                                    stream_index: stream_index,
                                    segment_index: params[:segment].to_i)
      return head(:not_found) unless File.exist?(path)
      send_file path, type: 'text/vtt', disposition: 'inline'
    end

    private

    def source_path
      @source_path ||= begin
        payload = Jellyfin::Transcoding::Token.decode(params[:token])
        payload[:path].to_s
      end
    end

    def stream_index
      params[:stream_index].to_i
    end

    def segmenter
      @segmenter ||= Jellyfin::Subtitle::Segmenter.new(
        ffmpeg_path: Jellyfin::Rails.configuration.ffmpeg_path,
        cache_root: Jellyfin::Rails.configuration.resolved_transcode_dir.to_s
      )
    end

    def ensure_segmented!
      @segmenter_result ||= segmenter.segment(
        source_path: source_path,
        stream_index: stream_index,
        segment_length: (params[:segment_length] || DEFAULT_SEGMENT_LENGTH).to_i
      )
    end

    def segmenter_result
      @segmenter_result
    end
  end
end
