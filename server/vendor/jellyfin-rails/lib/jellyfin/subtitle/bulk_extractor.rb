require 'fileutils'
require 'open3'

module Jellyfin
  module Subtitle
    # Port of SubtitleEncoder.ExtractAllExtractableSubtitles (cs:505). Pulls
    # every text subtitle stream from a media source out to disk in one
    # ffmpeg invocation. Used at library-scan time so subsequent playbacks
    # don't pay the per-segment extract cost.
    #
    # Returns an array of `{ stream_index:, path:, language:, format: }`
    # hashes for the files actually produced.
    class BulkExtractor
      TEXT_CODECS = %w[subrip srt ass ssa webvtt mov_text].freeze
      DEFAULT_FORMAT = 'srt'.freeze

      def initialize(ffmpeg_path: nil, cache_root: nil)
        @ffmpeg = ffmpeg_path || Jellyfin::Rails.configuration.ffmpeg_path
        @cache_root = cache_root || Jellyfin::Rails.configuration.resolved_transcode_dir.to_s
      end

      def extract_all(media_source)
        return [] unless media_source && File.exist?(media_source.path)
        text_streams = media_source.subtitle_streams.select { |s| TEXT_CODECS.include?(s.codec.to_s.downcase) }
        return [] if text_streams.empty?

        dir = cache_dir_for(media_source.path)
        FileUtils.mkdir_p(dir)

        # Single ffmpeg invocation extracting all text subs at once.
        # Upstream uses one process with N output specs; we do the same.
        args = [@ffmpeg, '-y', '-hide_banner', '-loglevel', 'error', '-i', media_source.path]
        outputs = text_streams.map do |s|
          out_path = File.join(dir, "#{s.index}.#{DEFAULT_FORMAT}")
          args.concat(['-map', "0:#{s.index}", '-c:s', codec_for(DEFAULT_FORMAT), out_path])
          { stream_index: s.index, path: out_path, language: s.language, format: DEFAULT_FORMAT }
        end

        _out, _err, status = Open3.capture3(*args)
        return [] unless status.success?
        outputs.select { |o| File.exist?(o[:path]) && File.size(o[:path]).positive? }
      end

      private

      def cache_dir_for(path)
        digest = Digest::SHA1.hexdigest(File.expand_path(path))[0, 16]
        File.join(@cache_root, 'subs', 'bulk', digest)
      end

      def codec_for(format)
        case format.to_s
        when 'srt' then 'srt'
        when 'vtt' then 'webvtt'
        when 'ass', 'ssa' then 'ass'
        end
      end
    end
  end
end
