# Technical probe (codec, duration, resolution) via ffprobe.
#
# Mirror of `example.rb` MediaIdentifier::TechProbe (lines 118-136), but
# shells out to the ffprobe binary directly instead of pulling in
# streamio-ffmpeg. Reuses the binary-resolution helper from
# TranscoderService so vendored vs. system lookup stays in one place.
#
# The shape returned matches TranscoderService.probe exactly, so the same
# data can drive both the at-scan-time cache (TechProbeJob writes
# tech_metadata) and the live playback start path (which historically
# called TranscoderService.probe directly).
#
# Public API:
#   TechProbeService.probe(file_path) -> Hash | nil
#     Live ffprobe call. Returns nil on failure.
#
#   TechProbeService.probe_for(record) -> Hash
#     Returns cached tech_metadata if present (and file size matches),
#     otherwise probes live, caches, and returns. Always returns a hash
#     unless the file is unreadable.

require "open3"
require "json"

class TechProbeService
  BITMAP_SUBTITLE_CODECS = %w[
    hdmv_pgs_subtitle dvd_subtitle dvb_subtitle pgssub xsub
  ].freeze

  TEXT_SUBTITLE_CODECS = %w[
    ass ssa srt subrip webvtt mov_text hdmv_text_subtitle
    text ttml microdvd mpl2 pjs realtext sami stl
    subviewer subviewer1 vplayer
  ].freeze

  # Bump whenever the probe result shape changes in a way the consumers
  # depend on. Cache rows tagged with an older version are treated as
  # misses by `probe_for` and silently re-probed on next play. Lets us
  # add fields (e.g. video.color_transfer for HDR detection) without
  # having to manually re-scan the library.
  CACHE_SCHEMA_VERSION = 3

  class << self
    # Live ffprobe call. Returns nil on failure (never raises).
    def probe(file_path)
      return nil if file_path.blank? || !File.file?(file_path)

      args = %w[-v error -print_format json -show_format -show_streams]
      args << file_path

      stdout, stderr, status = Open3.capture3(TranscoderService.ffprobe_path, *args)
      unless status.success?
        Rails.logger.warn("[TechProbe] ffprobe exited #{status.exitstatus} for #{file_path}: #{stderr.to_s[0..200]}")
        return nil
      end

      build_result(JSON.parse(stdout), file_path)
    rescue => e
      Sentry.capture_exception(e, tags: { subsystem: "tech_probe" }) if defined?(Sentry) && Sentry.initialized?
      Rails.logger.warn("[TechProbe] failed for #{file_path}: #{e.message}")
      nil
    end

    # Return cached probe data for a record, or probe live and cache.
    # Symbolized keys to match the existing TranscoderService.probe shape.
    def probe_for(record)
      file_path = record&.file_path
      return nil unless file_path.present?

      cached = parse_cached(record)
      if cached &&
         cached["size_bytes"].to_i == safe_size(file_path) &&
         cached["_schema_v"].to_i >= CACHE_SCHEMA_VERSION
        return symbolize(cached)
      end

      data = probe(file_path)
      return nil unless data

      attrs = { tech_metadata: data.to_json }
      if data["duration"].to_f > 0 && record.respond_to?(:duration_seconds)
        attrs[:duration_seconds] = data["duration"].to_f.round
      end
      record.update_columns(attrs) if record.persisted?

      symbolize(data)
    end

    private

    def parse_cached(record)
      return nil unless record.respond_to?(:tech_metadata)
      raw = record.tech_metadata
      return nil if raw.blank?
      JSON.parse(raw)
    rescue JSON::ParserError
      nil
    end

    def safe_size(path)
      File.size(path)
    rescue SystemCallError
      0
    end

    # Builds the result hash. Keys match TranscoderService.probe so this
    # can be used as a drop-in replacement at the playback layer.
    def build_result(data, file_path)
      streams = data["streams"] || []
      video_stream = streams.find { |s| s["codec_type"] == "video" && s["codec_name"] != "mjpeg" }
      audio_streams = streams.select { |s| s["codec_type"] == "audio" }
      subtitle_streams = streams.select { |s| s["codec_type"] == "subtitle" }

      duration = data.dig("format", "duration").to_f
      bitrate = data.dig("format", "bit_rate")&.to_i
      format_name = data.dig("format", "format_name").to_s.downcase

      {
        "duration" => duration,
        "formatName" => format_name,
        "bitrate" => bitrate,
        "size_bytes" => safe_size(file_path),
        "video" => video_stream && {
          "codec" => video_stream["codec_name"],
          "width" => video_stream["width"],
          "height" => video_stream["height"],
          "profile" => video_stream["profile"],
          # ffprobe returns level as an integer matching the codec spec
          # (HEVC level_idc: 120=4.0, 150=5.0, 153=5.1, 156=5.2; H.264
          # level_idc: 40=4.0, 51=5.1). Used by DeviceProfile CodecProfile
          # VideoLevel conditions.
          "level" => video_stream["level"],
          "pix_fmt" => video_stream["pix_fmt"],
          "color_transfer" => video_stream["color_transfer"],
          "color_primaries" => video_stream["color_primaries"],
          "color_space" => video_stream["color_space"]
        },
        "audioStreams" => audio_streams.map { |s|
          {
            "index" => s["index"],
            "codec" => s["codec_name"],
            "channels" => s["channels"],
            "language" => s.dig("tags", "language") || "und",
            "title" => s.dig("tags", "title")
          }
        },
        "subtitleStreams" => subtitle_streams.map { |s|
          {
            "index" => s["index"],
            "codec" => s["codec_name"],
            "language" => s.dig("tags", "language") || "und",
            "title" => s.dig("tags", "title"),
            "isText" => TEXT_SUBTITLE_CODECS.include?(s["codec_name"])
          }
        },
        "has_bitmap_subtitle" => subtitle_streams.any? { |s| BITMAP_SUBTITLE_CODECS.include?(s["codec_name"]) },
        "probed_at" => Time.current.iso8601,
        "_schema_v" => CACHE_SCHEMA_VERSION
      }
    end

    # Recursively convert string keys to symbols at the top two levels
    # (matches the legacy TranscoderService.probe shape).
    def symbolize(data)
      return data unless data.is_a?(Hash)
      result = {}
      data.each do |k, v|
        key = k.to_s.to_sym
        result[key] =
          case v
          when Hash then v.transform_keys(&:to_sym)
          when Array then v.map { |item| item.is_a?(Hash) ? item.transform_keys(&:to_sym) : item }
          else v
          end
      end
      result
    end
  end
end
