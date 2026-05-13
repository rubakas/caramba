# Technical probe wrapper. Delegates ffprobe orchestration to
# Jellyfin::MediaEncoder::Probe and adapts its MediaSourceInfo POD into the
# Hash shape Caramba consumers already use (audio/subtitle selection, device
# profile matching, dev-mode playback pill). The record-level cache on
# Episode/Movie#tech_metadata stays — it survives server restarts and is keyed
# on file size, which is what we want for invalidation.

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

  CACHE_SCHEMA_VERSION = 5

  class << self
    # Live probe. Returns nil on failure (never raises).
    def probe(file_path)
      return nil if file_path.blank? || !File.file?(file_path)

      media_source = Jellyfin::MediaEncoder::Probe.from_path(file_path)
      build_result(media_source, file_path)
    rescue Jellyfin::MediaEncoder::Probe::ProbeFailed => e
      Rails.logger.warn("[TechProbe] ffprobe failed for #{file_path}: #{e.message}")
      nil
    rescue => e
      Sentry.capture_exception(e, tags: { subsystem: "tech_probe" }) if defined?(Sentry) && Sentry.initialized?
      Rails.logger.warn("[TechProbe] failed for #{file_path}: #{e.message}")
      nil
    end

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

    # Adapts MediaSourceInfo → Caramba's legacy Hash shape.
    def build_result(media_source, file_path)
      video = media_source.default_video_stream
      audio_streams = media_source.audio_streams
      subtitle_streams = media_source.subtitle_streams

      {
        "duration" => media_source.duration_seconds.to_f,
        "formatName" => media_source.format_name.to_s.downcase,
        "bitrate" => media_source.bit_rate,
        "size_bytes" => safe_size(file_path),
        "video" => video && {
          "codec" => video.codec,
          "width" => video.width,
          "height" => video.height,
          "profile" => video.profile,
          "level" => video.level,
          "r_frame_rate" => video.frame_rate,
          "avg_frame_rate" => video.avg_frame_rate,
          "pix_fmt" => video.pixel_format,
          "color_transfer" => video.color_transfer,
          "color_primaries" => video.color_primaries,
          "color_space" => video.color_space,
          "video_range_type" => video.video_range_type
        },
        "audioStreams" => audio_streams.map { |s|
          {
            "index" => s.index,
            "codec" => s.codec,
            "channels" => s.channels,
            "language" => s.language.presence || "und",
            "title" => s.title
          }
        },
        "subtitleStreams" => subtitle_streams.map { |s|
          codec = s.codec.to_s.downcase
          {
            "index" => s.index,
            "codec" => s.codec,
            "language" => s.language.presence || "und",
            "title" => s.title,
            "isText" => TEXT_SUBTITLE_CODECS.include?(codec)
          }
        },
        "has_bitmap_subtitle" => subtitle_streams.any? { |s| BITMAP_SUBTITLE_CODECS.include?(s.codec.to_s.downcase) },
        "probed_at" => Time.current.iso8601,
        "_schema_v" => CACHE_SCHEMA_VERSION
      }
    end

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
