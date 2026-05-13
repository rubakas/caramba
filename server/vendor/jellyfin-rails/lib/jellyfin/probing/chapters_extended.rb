module Jellyfin
  module Probing
    # Port of the extended chapter handling in
    # MediaBrowser.MediaEncoding.Probing.ProbeResultNormalizer (the slice
    # around chapter normalisation). Upstream:
    #
    #   - normalises chapter `start_time` + `end_time` to ticks
    #   - extracts the chapter title from the `tags.title` field
    #   - synthesises chapters from the source's runtime when ffprobe
    #     reports none and the source is a known DVD/BD title
    #   - drops trailing chapters whose timestamp exceeds the source's
    #     `RunTimeTicks` (some sources have phantom chapters past EOF)
    module ChaptersExtended
      TICKS_PER_SECOND = 10_000_000

      module_function

      # Normalises an array of raw ffprobe chapter hashes into our
      # MediaSourceInfo chapter shape: `{ id:, start_time:, end_time:, title: }`
      # with timestamps in seconds. Filters out trailing phantom chapters.
      def normalize(raw_chapters, run_time_seconds: nil)
        return [] unless raw_chapters.is_a?(Array)
        normalized = raw_chapters.map do |c|
          start_s = c['start_time']&.to_f
          end_s = c['end_time']&.to_f
          {
            id: c['id'],
            start_time: start_s,
            end_time: end_s,
            title: c.dig('tags', 'title') || c.dig('tags', 'TITLE')
          }
        end

        # Drop phantom chapters that start past EOF (or within 1s of EOF).
        if run_time_seconds && run_time_seconds.positive?
          normalized = normalized.reject { |c| c[:start_time] && c[:start_time] >= run_time_seconds - 1 }
        end

        normalized
      end

      # Mirrors the synthesised-chapter fallback upstream uses for sources
      # with no chapter metadata but a known runtime. Splits the source
      # into N equal-length chapters.
      def synthesize_uniform(run_time_seconds:, count: 10)
        return [] if run_time_seconds.nil? || run_time_seconds <= 0
        step = run_time_seconds.to_f / count
        count.times.map do |i|
          {
            id: i,
            start_time: i * step,
            end_time: (i + 1) * step,
            title: "Chapter #{i + 1}"
          }
        end
      end
    end
  end
end
