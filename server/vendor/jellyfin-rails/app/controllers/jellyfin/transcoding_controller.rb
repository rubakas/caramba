require 'digest'
require 'jellyfin/transcoding/token'
require 'jellyfin/transcoding/transcode_manager'
require 'jellyfin/transcoding/segment_waiter'
require 'jellyfin/media_encoder/probe'
require 'jellyfin/output/master_playlist_builder'

module Jellyfin
  class TranscodingController < ApplicationController
    # POST /transcode/start
    # body: { path, video_codec?, video_bitrate?, audio_codec?, audio_bitrate?,
    #         max_height?, audio_track?, video_track?, segment_length? }
    def start
      # The permit list mirrors the upstream StreamingRequestDto fields we
      # actually honour: codec / bitrate / track selection, segment length,
      # plus the Batch-J knobs that toggle ffmpeg behaviour per job.
      payload = params.permit(
        :path, :video_codec, :video_bitrate, :audio_codec, :audio_bitrate,
        :max_height, :video_track, :audio_track, :subtitle_track, :subtitle_mode,
        :segment_length, :start_time_ticks, :max_bitrate,
        # Batch-J ffmpeg knobs surfaced as request params:
        :auto_crop, :two_pass, :frame_interpolation, :target_framerate,
        :multi_audio_tracks, :force_accurate_seek, :enable_loudnorm, :enable_drc,
        :hls_encryption, :http_user_agent,
        concat_parts: [], http_headers: {}
      ).to_h.deep_symbolize_keys
      path = payload[:path].to_s

      unless Jellyfin::Rails.configuration.path_allowed?(path)
        return render json: { error: 'path not allowed' }, status: :forbidden
      end
      unless File.exist?(path)
        return render json: { error: 'file not found' }, status: :not_found
      end

      # Coerce numerics — Rails params come as strings.
      %i[video_bitrate audio_bitrate max_height video_track audio_track
         subtitle_track segment_length start_time_ticks max_bitrate
         target_framerate].each { |k| payload[k] = Integer(payload[k]) if payload[k] }

      # Coerce booleans — accept "true"/"1"/true.
      %i[auto_crop two_pass frame_interpolation multi_audio_tracks
         force_accurate_seek enable_loudnorm enable_drc hls_encryption].each do |k|
        payload[k] = ActiveModel::Type::Boolean.new.cast(payload[k]) if payload.key?(k)
      end

      token = Jellyfin::Transcoding::Token.encode(payload)
      render json: {
        token: token,
        master_url: jellyfin_master_url(token),
        variant_url: jellyfin_variant_url(token),
        segment_url_template: jellyfin_segment_url_template(token)
      }
    rescue Jellyfin::Transcoding::Token::InvalidToken => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # GET /transcode/:token/master.m3u8
    #
    # Mirrors DynamicHlsHelper.GetMasterPlaylistInternal: builds the master
    # playlist string from the probed source + the variant playlist URL.
    # Subtitle / audio / closed-caption / trickplay rendition groups are
    # included when present.
    def master
      params_hash = decode_or_400!(params[:token]) or return
      job = manager.ensure_started(id: derive_job_id(params[:token]), params: params_hash)
      job.ping!
      wait_for_playlist!(job)

      media_source = probe_or_nil(params_hash[:path])
      variant_url = "main.m3u8"
      total_bitrate = ((params_hash[:video_bitrate] || 2_000_000).to_i +
                       (params_hash[:audio_bitrate] || 128_000).to_i)

      master = Jellyfin::Output::MasterPlaylistBuilder.build(
        job: job,
        variant_url: variant_url,
        total_bitrate: total_bitrate,
        video_stream: media_source&.default_video_stream,
        audio_stream: media_source&.default_audio_stream,
        subtitle_tracks: build_subtitle_tracks(media_source, params[:token]),
        trickplay_resolutions: build_trickplay_resolutions(params[:token]),
        has_closed_captions: media_source &&
          Jellyfin::Subtitle::ClosedCaptions.present?(media_source.default_video_stream),
        is_live_stream: live_stream?(media_source)
      )

      render plain: master, content_type: 'application/vnd.apple.mpegurl'
    end

    # GET /transcode/:token/main.m3u8 — the actual variant playlist that
    # ffmpeg's hls muxer produces. Master playlist references this URL.
    def variant
      params_hash = decode_or_400!(params[:token]) or return
      job = manager.ensure_started(id: derive_job_id(params[:token]), params: params_hash)
      job.ping!
      wait_for_playlist!(job)
      send_file job.playlist_path, type: 'application/vnd.apple.mpegurl', disposition: 'inline'
    end

    # GET /transcode/:token/:segment.ts
    def segment
      params_hash = decode_or_400!(params[:token]) or return
      job = manager.ensure_started(id: derive_job_id(params[:token]), params: params_hash)
      segment_id = params[:segment].to_i
      manager.note_segment_served(job.id, segment_id)

      file = Jellyfin::Transcoding::SegmentWaiter.wait(job, segment_id)
      if file.nil?
        return render json: { error: 'segment timeout' }, status: :gateway_timeout
      end
      send_file file, type: 'video/mp2t', disposition: 'inline'
    end

    private

    def manager
      Jellyfin::Transcoding::TranscodeManager.instance
    end

    def decode_or_400!(token)
      Jellyfin::Transcoding::Token.decode(token)
    rescue Jellyfin::Transcoding::Token::InvalidToken => e
      render json: { error: e.message }, status: :bad_request
      nil
    end

    def derive_job_id(token)
      Digest::SHA1.hexdigest(token)[0, 16]
    end

    def wait_for_playlist!(job, timeout: 10)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until File.exist?(job.playlist_path) && File.size(job.playlist_path) > 0
        return if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.05
      end
    end

    def jellyfin_master_url(token)
      "#{request.base_url}#{Jellyfin::Rails::Engine.routes.url_helpers.master_path(token: token)}"
    end

    def jellyfin_segment_url_template(token)
      mount = jellyfin_master_url(token).sub(%r{/master\.m3u8\z}, '')
      "#{mount}/%d.ts"
    end

    def jellyfin_variant_url(token)
      "#{request.base_url}#{Jellyfin::Rails::Engine.routes.url_helpers.variant_path(token: token)}"
    end

    # Ports the live-stream detection from EncodingJobInfo.IsSegmentedLiveStream:
    # a source with no known duration is treated as live (no trickplay, no
    # bandwidth ladder, sliding-window playlist).
    def live_stream?(media_source)
      return false unless media_source
      media_source.run_time_ticks.nil? || media_source.run_time_ticks.to_i.zero?
    end

    def probe_or_nil(path)
      return nil unless path && File.exist?(path)
      Jellyfin::MediaEncoder::Probe.from_path(path)
    rescue StandardError
      nil
    end

    # Mirrors DynamicHlsHelper.AddSubtitles: enumerate text subtitle streams,
    # build their per-track HLS playlist URLs, and tag the selected/default.
    def build_subtitle_tracks(media_source, token)
      return [] unless media_source
      streams = media_source.subtitle_streams.select { |s| text_sub?(s) }
      streams.map do |s|
        uri = Jellyfin::Rails::Engine.routes.url_helpers.webvtt_index_path(
          token: token, stream_index: s.index
        )
        { stream_index: s.index, uri: uri,
          name: s.title || s.language || "Subtitle #{s.index}",
          language: s.language, default: s.is_default, forced: s.is_forced,
          selected: false }
      end
    end

    def text_sub?(stream)
      %w[subrip srt ass ssa webvtt mov_text].include?(stream.codec.to_s.downcase)
    end

    # Mirrors DynamicHlsHelper.AddTrickplay: enumerate trickplay widths the
    # server can produce and emit one EXT-X-IMAGE-STREAM-INF per width. We
    # emit two upstream defaults (320, 480) — production deploys can extend.
    def build_trickplay_resolutions(token)
      [320, 480].map do |w|
        uri = Jellyfin::Rails::Engine.routes.url_helpers.trickplay_index_path(
          token: token, width: w
        )
        h = (w * 9 / 16).to_i # 16:9 default
        # bandwidth is roughly 1 byte/pixel — upstream's TrickplayInfo.Bandwidth.
        { width: w, height: h, bandwidth: (w * h * 8), uri: uri }
      end
    end
  end
end
