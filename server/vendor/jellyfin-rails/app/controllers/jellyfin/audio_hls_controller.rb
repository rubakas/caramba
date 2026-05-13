require 'digest'
require 'jellyfin/transcoding/token'
require 'jellyfin/transcoding/transcode_manager'
require 'jellyfin/transcoding/segment_waiter'
require 'jellyfin/media_encoder/probe'
require 'jellyfin/encoding/audio_hls'
require 'jellyfin/output/master_playlist_builder'

module Jellyfin
  # Audio-only HLS pipeline. Mirrors upstream `DynamicHlsController`'s audio
  # endpoints — distinct from `/audio_stream/:token/stream` (progressive) and
  # from `/transcode/:token/master.m3u8` (general video+audio HLS).
  #
  #   GET /audio_hls/:token/master.m3u8          → MasterHlsAudio
  #   GET /audio_hls/:token/main.m3u8            → VariantHlsAudio
  #   GET /audio_hls/:token/:segment.:container  → HlsAudioSegment
  class AudioHlsController < ApplicationController
    SEGMENT_FORMATS = %w[aac m4s mp4 ts].freeze

    # Port of DynamicHlsController.GetMasterHlsAudioPlaylist (cs:582).
    def master
      payload = decode_or_400!(params[:token]) or return
      media = probe_or_nil(payload[:path])
      variant_url = 'main.m3u8'
      total_bitrate = (payload[:audio_bitrate] || 192_000).to_i

      master = Jellyfin::Output::MasterPlaylistBuilder.build(
        job: nil, variant_url: variant_url, total_bitrate: total_bitrate,
        video_stream: nil, audio_stream: media&.default_audio_stream,
        is_live_stream: live?(media)
      )
      render plain: master, content_type: 'application/vnd.apple.mpegurl'
    end

    # Port of GetVariantHlsAudioPlaylist (cs:918). Serves the ffmpeg-generated
    # variant playlist for an audio-only HLS job.
    def variant
      payload = decode_or_400!(params[:token]) or return
      job = ensure_audio_job(payload)
      wait_for_playlist!(job)
      send_file job.playlist_path, type: 'application/vnd.apple.mpegurl', disposition: 'inline'
    end

    # Port of GetHlsAudioSegment (cs:1273).
    def segment
      payload = decode_or_400!(params[:token]) or return
      job = ensure_audio_job(payload)
      seg_id = params[:segment].to_i
      Jellyfin::Transcoding::TranscodeManager.instance.note_segment_served(job.id, seg_id)
      file = Jellyfin::Transcoding::SegmentWaiter.wait(job, seg_id)
      return render(json: { error: 'segment timeout' }, status: :gateway_timeout) if file.nil?
      send_file file, type: mime_for(params[:container]), disposition: 'inline'
    end

    private

    def ensure_audio_job(payload)
      # Tag the params so TranscodeManager#build_args picks the audio-only
      # codepath. We embed a marker rather than fork the manager wholesale.
      payload = payload.merge(audio_hls: true)
      Jellyfin::Transcoding::TranscodeManager.instance.ensure_started(
        id: "audio-#{Digest::SHA1.hexdigest(params[:token])[0, 16]}",
        params: payload
      ).tap(&:ping!)
    end

    def decode_or_400!(token)
      Jellyfin::Transcoding::Token.decode(token)
    rescue Jellyfin::Transcoding::Token::InvalidToken => e
      render json: { error: e.message }, status: :bad_request
      nil
    end

    def probe_or_nil(path)
      return nil unless path && File.exist?(path)
      Jellyfin::MediaEncoder::Probe.from_path(path)
    rescue StandardError
      nil
    end

    def live?(media)
      return false unless media
      media.run_time_ticks.nil? || media.run_time_ticks.to_i.zero?
    end

    def wait_for_playlist!(job, timeout: 10)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until File.exist?(job.playlist_path) && File.size(job.playlist_path) > 0
        return if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.05
      end
    end

    def mime_for(container)
      case container.to_s.downcase
      when 'aac' then 'audio/aac'
      when 'm4s', 'mp4' then 'audio/mp4'
      when 'ts' then 'video/mp2t'
      else 'application/octet-stream'
      end
    end
  end
end
