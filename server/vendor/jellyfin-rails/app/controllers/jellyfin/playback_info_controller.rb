require 'jellyfin/transcoding/token'
require 'jellyfin/media_encoder/probe'
require 'jellyfin/playback/playback_info'
require 'jellyfin/playback/client_profile'

module Jellyfin
  # POST /playback_info — capability negotiation. The client posts a target
  # path plus its profile (h264_profiles, max_video_height, etc.) and we
  # return which delivery method it should use:
  #   - direct_play  → stream the original file
  #   - direct_stream → remux container only
  #   - transcode    → full re-encode through HLS
  class PlaybackInfoController < ApplicationController
    # GET /playback_info — upstream's `GET /Items/{id}/PlaybackInfo` variant.
    # Same semantics as POST but params come from the query string instead of
    # the body. Mirrors MediaInfoController.cs which decorates the same
    # method with both [HttpGet] and [HttpPost] attributes.
    def show
      create
    end

    def create
      raw = params.permit(:path, :audio_track, :subtitle_track, :max_bitrate,
                          client: {}).to_h.deep_symbolize_keys
      path = raw[:path].to_s

      unless Jellyfin::Rails.configuration.path_allowed?(path)
        return render json: { error: 'path not allowed' }, status: :forbidden
      end
      unless File.exist?(path)
        return render json: { error: 'file not found' }, status: :not_found
      end

      media_source = Jellyfin::MediaEncoder::Probe.from_path(path)
      profile = build_profile(raw[:client] || {})

      transcode_token = Jellyfin::Transcoding::Token.encode(
        path: path,
        audio_track: raw[:audio_track],
        subtitle_track: raw[:subtitle_track],
        max_bitrate: raw[:max_bitrate]
      )
      direct_token = Jellyfin::Transcoding::Token.encode(path: path)

      info = Jellyfin::Playback::PlaybackInfo.for(
        media_source: media_source,
        profile: profile,
        audio_track: raw[:audio_track]&.to_i,
        subtitle_track: raw[:subtitle_track]&.to_i,
        max_bitrate: raw[:max_bitrate]&.to_i,
        base_url: request.base_url,
        token_for_direct: direct_token,
        token_for_transcode: transcode_token
      )

      render json: info.to_h_serializable.merge(
        media_source: {
          id: media_source.id,
          container: media_source.container,
          run_time_ticks: media_source.run_time_ticks,
          bit_rate: media_source.bit_rate,
          video_streams: media_source.video_streams.map { |s| stream_summary(s) },
          audio_streams: media_source.audio_streams.map { |s| stream_summary(s) },
          subtitle_streams: media_source.subtitle_streams.map { |s| stream_summary(s) }
        }
      )
    rescue Jellyfin::MediaEncoder::Probe::ProbeFailed => e
      render json: { error: "probe failed: #{e.message}" }, status: :unprocessable_entity
    end

    private

    def build_profile(client)
      kind = client[:kind].to_s
      profile = case kind
                when 'safari'      then Jellyfin::Playback::ClientProfile.safari
                when 'appletv_4k'  then Jellyfin::Playback::ClientProfile.appletv_4k
                else                    Jellyfin::Playback::ClientProfile.modern_browser
                end
      # Caller can override individual fields.
      %i[max_video_bitrate max_video_height max_video_width max_video_fps
         max_audio_channels supports_hdr supports_10bit].each do |k|
        next unless client.key?(k)
        profile.public_send("#{k}=", client[k])
      end
      profile
    end

    def stream_summary(s)
      {
        index: s.index, type: s.type, codec: s.codec, language: s.language,
        title: s.title, is_default: s.is_default, is_forced: s.is_forced,
        width: s.width, height: s.height, channels: s.channels,
        bit_rate: s.bit_rate, frame_rate: s.frame_rate,
        video_range_type: s.video_range_type
      }.compact
    end
  end
end
