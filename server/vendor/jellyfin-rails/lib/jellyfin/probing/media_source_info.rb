module Jellyfin
  module Probing
    # POD for an entire media source — mirrors MediaBrowser.Model.Dto.MediaSourceInfo
    # at the level of detail jellyfin-rails consumes.
    class MediaSourceInfo
      attr_accessor :id, :path, :protocol, :container, :run_time_ticks,
                    :bit_rate, :size, :format_name, :streams, :chapters,
                    :programs, :tags

      TICKS_PER_SECOND = 10_000_000

      def initialize(**attrs)
        @streams  = attrs.fetch(:streams, [])
        @chapters = attrs.fetch(:chapters, [])
        @programs = attrs.fetch(:programs, [])
        @tags     = attrs.fetch(:tags, {})
        attrs.each { |k, v| instance_variable_set(:"@#{k}", v) unless %i[streams chapters programs tags].include?(k) }
      end

      # Returns the source's effective overall bitrate, falling back to
      # `size * 8 / duration_seconds` when ffprobe didn't carry a top-level
      # `bit_rate` (common for MKVs).
      def effective_bit_rate
        return bit_rate if bit_rate && bit_rate > 0
        return nil unless size && duration_seconds && duration_seconds > 0
        ((size.to_f * 8) / duration_seconds).to_i
      end

      def has_chapters?
        !chapters.empty?
      end

      def hdr?
        video_streams.any?(&:hdr?)
      end

      def duration_seconds
        return nil unless run_time_ticks
        run_time_ticks.to_f / TICKS_PER_SECOND
      end

      def video_streams    = streams.select(&:video?)
      def audio_streams    = streams.select(&:audio?)
      def subtitle_streams = streams.select(&:subtitle?)

      def default_video_stream    = video_streams.find { |s| s.is_default } || video_streams.first
      def default_audio_stream    = audio_streams.find { |s| s.is_default } || audio_streams.first
      def default_subtitle_stream = subtitle_streams.find { |s| s.is_default }

      def to_h
        {
          id: id,
          path: path,
          protocol: protocol,
          container: container,
          run_time_ticks: run_time_ticks,
          duration_seconds: duration_seconds,
          bit_rate: bit_rate,
          effective_bit_rate: effective_bit_rate,
          size: size,
          format_name: format_name,
          streams: streams.map(&:to_h),
          chapters: chapters,
          programs: programs,
          tags: tags,
          hdr: hdr?
        }
      end
    end
  end
end
