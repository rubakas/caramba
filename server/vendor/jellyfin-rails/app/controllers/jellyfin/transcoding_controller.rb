require 'digest'
require 'jellyfin/transcoding/token'
require 'jellyfin/transcoding/transcode_manager'
require 'jellyfin/transcoding/segment_waiter'
require 'jellyfin/media_encoder/probe'
require 'jellyfin/output/master_playlist_builder'
require 'jellyfin/output/vod_playlist_generator'
require 'jellyfin/encoding/encoding_job_info'
require 'jellyfin/keyframes/extractor'

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
        :segment_length, :segment_container, :start_time_ticks, :max_bitrate,
        # Master-playlist rendition gating — see Token payload schema.
        :subtitle_delivery, :trickplay,
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
         force_accurate_seek enable_loudnorm enable_drc hls_encryption
         trickplay].each do |k|
        next unless payload.key?(k)
        v = payload[k]
        payload[k] = v == true || %w[1 true yes on t].include?(v.to_s.downcase)
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
    # Mirrors DynamicHlsHelper.GetMasterPlaylistInternal. The rendition
    # groups (`EXT-X-MEDIA:TYPE=SUBTITLES`, `EXT-X-IMAGE-STREAM-INF`) are
    # emitted based on token-baked client choices:
    #
    #   subtitle_delivery == 'hls' → emit subtitle MEDIA group
    #   trickplay == true         → emit image stream-inf entries
    #
    # Anything else (default: subs external, trickplay off) yields a
    # bare master with just the variant STREAM-INF, matching what
    # upstream Jellyfin emits for clients whose DeviceProfile declared
    # `SubtitleDeliveryMethod=External`. Caramba's clients fall into this
    # category — they render subtitles client-side via external WebVTT
    # and don't use HLS trickplay.
    def master
      params_hash = decode_or_400!(params[:token]) or return
      job = manager.ensure_started(id: derive_job_id(params[:token]), params: params_hash)
      job.ping!

      media_source = probe_or_nil(params_hash[:path])
      variant_url = "main.m3u8"
      total_bitrate = ((params_hash[:video_bitrate] || 2_000_000).to_i +
                       (params_hash[:audio_bitrate] || 128_000).to_i)

      # Compute the codecs ffmpeg actually emits, using the same defaults
      # the transcoding pipeline does (libx264 / aac). Pass them to the
      # master playlist builder so the CODECS attribute reflects what's on
      # the wire — see Jellyfin::Encoding::EncodingJobInfo#actual_output_*
      # for the rationale (mirrors upstream's ActualOutputVideoCodec).
      source_video = media_source&.default_video_stream
      source_audio = media_source&.default_audio_stream
      output_info = if media_source
                      Jellyfin::Encoding::EncodingJobInfo.new(
                        media_source: media_source,
                        output_video_codec: params_hash[:video_codec] || 'libx264',
                        output_audio_codec: params_hash[:audio_codec] || 'aac'
                      )
      end

      hls_subs = params_hash[:subtitle_delivery].to_s.casecmp?('hls')
      trickplay_on = truthy?(params_hash[:trickplay])

      master = Jellyfin::Output::MasterPlaylistBuilder.build(
        job: job,
        variant_url: variant_url,
        total_bitrate: total_bitrate,
        video_stream: source_video,
        audio_stream: source_audio,
        output_video_codec: output_info&.actual_output_video_codec,
        output_audio_codec: output_info&.actual_output_audio_codec,
        subtitle_tracks: hls_subs ? build_subtitle_tracks(media_source, params[:token]) : [],
        trickplay_resolutions: trickplay_on ? build_trickplay_resolutions(params[:token]) : [],
        has_closed_captions: hls_subs && media_source &&
          Jellyfin::Subtitle::ClosedCaptions.present?(media_source.default_video_stream),
        is_live_stream: live_stream?(media_source)
      )

      render plain: master, content_type: 'application/vnd.apple.mpegurl'
    end

    # GET /transcode/:token/main.m3u8 — the variant playlist.
    #
    # For finite-duration sources we hand-build a complete VOD playlist
    # (every segment + EXT-X-ENDLIST) from the probed runtime, mirroring
    # upstream DynamicHlsPlaylistGenerator.CreateMainPlaylist. Sending
    # ffmpeg's in-progress playlist instead works in hls.js but fails on
    # Safari's native HLS engine — see VodPlaylistGenerator for details.
    # Live streams (no probe-able run time) fall back to ffmpeg's playlist
    # since we don't know the total upfront.
    def variant
      params_hash = decode_or_400!(params[:token]) or return
      job = manager.ensure_started(id: derive_job_id(params[:token]), params: params_hash)
      job.ping!

      media_source = probe_or_nil(params_hash[:path])
      vod_body = build_vod_playlist(media_source, params_hash, job)
      if vod_body
        return render plain: vod_body, content_type: 'application/vnd.apple.mpegurl'
      end

      wait_for_playlist!(job)
      send_file job.playlist_path, type: 'application/vnd.apple.mpegurl', disposition: 'inline'
    end

    # GET /transcode/:token/:segment.(ts|mp4)
    def segment
      params_hash = decode_or_400!(params[:token]) or return
      job = manager.ensure_started(id: derive_job_id(params[:token]), params: params_hash)
      segment_id = params[:segment].to_i
      manager.note_segment_served(job.id, segment_id)

      file = Jellyfin::Transcoding::SegmentWaiter.wait(job, segment_id)
      if file.nil?
        return render json: { error: 'segment timeout' }, status: :gateway_timeout
      end
      send_file file, type: segment_content_type(job), disposition: 'inline'
    end

    # GET /transcode/:token/-1.mp4 — fMP4 init segment.
    #
    # ffmpeg writes this once at the start of an fmp4 HLS encode (via
    # `-hls_fmp4_init_filename -1.mp4`). The master playlist references
    # it through `#EXT-X-MAP:URI="-1.mp4"`. Clients fetch it before any
    # media segment so they have the codec setup boxes (moov/trak/stsd).
    #
    # The init file is NOT covered by `-hls_flags +temp_file`; ffmpeg
    # writes it incrementally and only finalises it once the first
    # media segment is being flushed. So polling on
    # `File.exist?(init) && size > 0` raced with ffmpeg's write —
    # `send_file` could ship a partially-written init.mp4 (missing
    # parts of moov/trak/stsd), Safari rejected it with
    # MEDIA_ERR_DECODE, retried, and the pattern repeated every ~6 s
    # (each retry triggered a fresh ffmpeg startup + first-segment
    # buffering when the previous one had already exited).
    #
    # Synchronise on the existence of the FIRST media segment instead.
    # ffmpeg writes media[0] only after init has been fully flushed,
    # so by the time `0.mp4` shows up on disk, `-1.mp4` is guaranteed
    # complete.
    def init_segment
      params_hash = decode_or_400!(params[:token]) or return
      job = manager.ensure_started(id: derive_job_id(params[:token]), params: params_hash)
      job.ping!
      init_path = job.init_segment_path
      first_seg = job.segment_path(0)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      until init_path && File.exist?(init_path) && File.exist?(first_seg)
        return render(json: { error: 'init segment timeout' }, status: :gateway_timeout) if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.05
      end
      send_file init_path, type: 'video/mp4', disposition: 'inline'
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

    def truthy?(value)
      return value if value == true || value == false
      %w[1 true yes on t].include?(value.to_s.downcase)
    end

    def segment_content_type(job)
      job.segment_container == 'mp4' ? 'video/mp4' : 'video/mp2t'
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

    # Hand-builds a complete VOD variant playlist from the probed runtime.
    # Returns nil for live streams (caller falls back to ffmpeg's playlist).
    # Mirrors upstream
    # Jellyfin.MediaEncoding.Hls/Playlist/DynamicHlsPlaylistGenerator.cs#CreateMainPlaylist.
    def build_vod_playlist(media_source, params_hash, job)
      return nil if media_source.nil? || live_stream?(media_source)

      total_seconds = media_source.run_time_ticks.to_f /
                      Jellyfin::Output::VodPlaylistGenerator::TICKS_PER_SECOND
      seek_seconds = (params_hash[:start_time_ticks].to_f /
                      Jellyfin::Output::VodPlaylistGenerator::TICKS_PER_SECOND)
      seg_len = job.segment_length_seconds

      # For stream-copy video, segment boundaries fall on source
      # keyframes, so the playlist's `#EXTINF` values have to match the
      # source's real keyframe intervals — equal-length segments break
      # Safari with MEDIA_ERR_DECODE on the first PTS mismatch. The
      # extractor reads the MKV Cues block directly (no packet scan),
      # so this stays sub-millisecond on first request. Mirrors upstream
      # DynamicHlsPlaylistGenerator.cs:34-47 (`IsRemuxingVideo` branch).
      keyframe_seconds = nil
      if params_hash[:video_codec].to_s == 'copy'
        keyframe_seconds = Jellyfin::Keyframes::Extractor.for(params_hash[:path])&.keyframe_seconds
      end

      # Container is locked at job creation (see TranscodingJob#initialize)
      # so a single token's playlist + media segments stay consistent.
      # fMP4 jobs use `-1.mp4` as the init segment (EXT-X-MAP URI) and
      # `N.mp4` for media fragments; mpegts uses `N.ts`.
      Jellyfin::Output::VodPlaylistGenerator.build(
        total_duration_seconds: total_seconds,
        segment_length_seconds: seg_len,
        seek_seconds: seek_seconds,
        segment_extension: job.segment_extension,
        container: job.segment_container,
        init_segment_uri: job.segment_container == 'mp4' ? '-1.mp4' : nil,
        keyframe_seconds: keyframe_seconds
      )
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
      [ 320, 480 ].map do |w|
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
