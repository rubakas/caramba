# Sentry PII scrubbers — Ruby port of ui/sentry/scrubbers.js.
# See docs/superpowers/specs/2026-04-22-sentry-integration-design.md
# for the "aggressive scrubbing" rationale.
module Sentry
  module Scrubbers
    MEDIA_EXT = "(mkv|mp4|avi|webm|m4v|mov|mp3|flac|srt|vtt|ass)".freeze
    HOME_PATH_RE = %r{/(Users|home)/[^/"'`<>]+?/}.freeze
    MEDIA_FILE_RE = /[\w.\-]+\.#{MEDIA_EXT}/i.freeze
    NUMERIC_ID_RE = %r{/\d+(?=/|\z|\?)}.freeze
    UUID_RE = %r{/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?=/|\z|\?)}i.freeze
    SEARCH_TERM_RE = /(Failed to fetch (?:TVMaze|IMDb)[^:]*:\s*)(.+)/.freeze

    def self.scrub_string(input)
      return input unless input.is_a?(String)
      input
        .gsub(HOME_PATH_RE, "~/")
        .gsub(MEDIA_FILE_RE) { |match| "*#{match[match.rindex(".")..].downcase}" }
        .gsub(SEARCH_TERM_RE, '\1<redacted>')
    end

    def self.scrub_url(input)
      return input unless input.is_a?(String)
      base = input.split("?").first
      base
        .gsub(UUID_RE, "/:id")
        .gsub(NUMERIC_ID_RE, "/:id")
    end

    def self.before_send(event)
      return event unless event
      event[:message] = scrub_string(event[:message]) if event[:message]
      if (req = event[:request])
        req[:url] = scrub_url(req[:url]) if req[:url]
        req[:query_string] = "" if req[:query_string]
      end
      values = event.dig(:exception, :values)
      if values.is_a?(Array)
        values.each do |v|
          v[:value] = scrub_string(v[:value]) if v[:value]
          frames = v.dig(:stacktrace, :frames)
          if frames.is_a?(Array)
            frames.each do |f|
              f[:filename] = scrub_string(f[:filename]) if f[:filename]
              f[:abs_path] = scrub_string(f[:abs_path]) if f[:abs_path]
            end
          end
        end
      end
      if event[:user].is_a?(Hash) && event[:user][:username]
        event[:user].delete(:username)
      end
      event
    end

    def self.before_breadcrumb(crumb)
      return crumb unless crumb
      crumb[:message] = scrub_string(scrub_url(crumb[:message])) if crumb[:message]
      if (data = crumb[:data])
        data[:url] = scrub_url(data[:url]) if data[:url]
        data[:to] = scrub_url(data[:to]) if data[:to]
        data[:from] = scrub_url(data[:from]) if data[:from]
      end
      crumb
    end
  end
end
