require 'open3'
require 'fileutils'
require 'json'
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

    # Bump when the ffmpeg extraction args change in a way that affects cue
    # timing or content. Folded into the cache key so old `.vtt` files from
    # a prior extractor version aren't served.
    #
    # v2 (2026-05-16): added `-copyts -an -vn` to preserve subtitle PTS.
    #                  Produced empty output on some sources — the muxer's
    #                  default avoid_negative_ts and the spurious `-an -vn`
    #                  interacted badly with `-map 0:s:N`.
    # v3 (2026-05-16): dropped `-an -vn` (extraneous given explicit -map),
    #                  kept `-copyts`. The WebVTT muxer still produced
    #                  empty output on at least one real source (The
    #                  Office S01E01) — likely because its subtitle stream
    #                  has timing the muxer rejects when timestamps are
    #                  preserved. The empty-output guard then surfaces as
    #                  "no subtitles at all" in the UI.
    # v4 (2026-05-16): reverted `-copyts`. Trade-off: cues fired a few
    #                  seconds before the dialogue on files whose first
    #                  subtitle PTS isn't 0, but subtitles actually
    #                  rendered.
    # v5 (2026-05-16): keep the no-`-copyts` extraction, then ffprobe
    #                  the subtitle stream's `start_time` and shift cues
    #                  forward by that amount via Converter.
    # v6 (2026-05-16): added `-fflags +discardcorrupt` and partial-file
    #                  cleanup on ffmpeg failure. On a 30 GB 4K HEVC HDR
    #                  source (Devil Wears Prada), the demuxer hit a
    #                  read error mid-stream and exited non-zero, but
    #                  the partially-written .vtt (3 KB / 39 cues, song
    #                  lyrics only) was left in the cache and served on
    #                  every subsequent request — the user got "only the
    #                  first 3 minutes have subs" with no way to retry.
    EXTRACTOR_VERSION = 6

    def cache_path_for(path, index, format)
      stat = File.stat(path)
      dir = File.join(Jellyfin::Rails.configuration.resolved_transcode_dir.to_s, 'subs')
      FileUtils.mkdir_p(dir)
      key = Digest::SHA1.hexdigest(
        [path, stat.mtime.to_i, stat.size, index, format, EXTRACTOR_VERSION].join('|')
      )[0, 16]
      File.join(dir, "#{key}.#{format}")
    end

    def extract_to(out_path, src_path, index, format)
      ffmpeg = Jellyfin::Rails.configuration.ffmpeg_path
      # No `-copyts` here. ffmpeg's default `avoid_negative_ts make_zero`
      # shifts the output's first PTS to 0; we DELIBERATELY accept that
      # shift and undo it ourselves below (`apply_pts_shift!`) because
      # `-copyts` silently produces an empty `.vtt` on at least one real
      # source (The Office S01E01, confirmed 2026-05-16) and there's no
      # flag combination that's reliable across the engine's ffmpeg build.
      #
      # `-fflags +discardcorrupt`: be lenient about read errors mid-file.
      # 4K HEVC sources stored on external/network volumes can hit
      # transient read failures during the long single-pass scan that
      # subtitle extraction performs; without this, ffmpeg exits non-zero
      # the first time it hits a bad block and we lose the rest of the
      # stream (Devil Wears Prada @ /Volumes/1TB, 2026-05-16: died at
      # byte 513 M, cached 3 KB of a 500 KB stream — 39 cues out of
      # ~1300, song lyrics only).
      _out, err, status = Open3.capture3(
        ffmpeg, '-y', '-hide_banner', '-loglevel', 'warning',
        '-fflags', '+discardcorrupt',
        '-i', src_path, '-map', "0:s:#{index}",
        '-c:s', codec_for(format), out_path
      )
      # CRITICAL: clean up the partial output on ANY failure path so the
      # next request re-extracts instead of serving the truncated cache.
      # The old code left the partial file in place when ffmpeg exited
      # non-zero, and every subsequent request hit
      # `File.exist?(cache_path)` → skipped extraction → served the
      # broken stub.
      unless status.success?
        File.unlink(out_path) rescue nil
        raise "ffmpeg subtitle extract failed: #{err.strip}"
      end
      # Match upstream's empty-output guard (SubtitleEncoder.cs:900). ffmpeg
      # can exit 0 on flags it doesn't fully support and still produce a
      # zero-byte file; that file then loads as an empty <track> with no
      # cues — visible to the user as "subtitles silently stopped working"
      # with no error in any log. Surface it as a 5xx via the controller's
      # rescue so the regression is loud.
      if !File.exist?(out_path) || File.size(out_path) == 0
        File.unlink(out_path) rescue nil
        raise "ffmpeg subtitle extract produced empty output: #{err.strip}"
      end
      apply_pts_shift!(out_path, src_path, index, format)
    end

    # Re-applies the source subtitle stream's start_time offset to every
    # cue, undoing ffmpeg's default `avoid_negative_ts make_zero` shift.
    # Without this, cues on files whose first subtitle PTS isn't 0 (leading
    # silence, MP4 edit lists, codec priming) fire a few seconds before
    # the dialogue. Mirrors the original pre-port Caramba pipeline
    # (a5ad2da^ `TranscoderService#shift_vtt`), which applied an analogous
    # offset client-side per session.
    def apply_pts_shift!(out_path, src_path, index, format)
      shift_seconds = subtitle_stream_start_time(src_path, index)
      return if shift_seconds <= 0
      raw = File.read(out_path)
      # `Converter#filter_events` treats `start_position_ticks` as the
      # amount to SUBTRACT from each cue. Passing a negative value adds
      # to every cue — exactly the forward shift we need. preserve=false
      # is required so the math runs at all (preserve=true is a no-op).
      shifted = Jellyfin::Subtitle::Converter.convert(
        text: raw,
        input_format: format,
        output_format: format,
        start_time_ticks: -(shift_seconds * Jellyfin::Subtitle::Converter::TICKS_PER_SECOND).to_i,
        end_time_ticks: 0,
        preserve_original_timestamps: false
      )
      File.write(out_path, shifted)
    end

    # ffprobe the requested subtitle stream's container `start_time`.
    # That's the offset ffmpeg silently subtracted during extraction, so
    # it's what we need to add back. Falls back to 0 (no shift) on any
    # parse failure — better to ship slightly-early cues than no cues.
    # Notes:
    #   - `-select_streams s:N` matches subtitle-relative index, same as
    #     the `0:s:N` -map used during extraction.
    #   - `start_time` is reported in seconds (decimal), e.g. "3.000000".
    #   - Some containers report "N/A" for streams without a start offset;
    #     `.to_f` of "N/A" is 0.0, which is the right no-op outcome.
    def subtitle_stream_start_time(src_path, index)
      ffprobe = Jellyfin::Rails.configuration.ffprobe_path
      out, _err, status = Open3.capture3(
        ffprobe, '-v', 'error',
        '-select_streams', "s:#{index}",
        '-show_entries', 'stream=start_time',
        '-of', 'json', src_path
      )
      return 0.0 unless status.success?
      streams = JSON.parse(out).fetch('streams', [])
      streams.first&.dig('start_time').to_f
    rescue JSON::ParserError
      0.0
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
