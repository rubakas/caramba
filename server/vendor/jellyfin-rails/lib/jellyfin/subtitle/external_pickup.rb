require 'pathname'

module Jellyfin
  module Subtitle
    # Mirrors SubtitleScanner.cs / SubtitleResolver.cs: when a video file is
    # opened we look for sidecar subtitle files in the same directory. The
    # naming conventions Jellyfin recognises:
    #
    #   <basename>.<lang>.<format>           video.en.srt
    #   <basename>.<lang>.forced.<format>    video.en.forced.srt
    #   <basename>.forced.<format>           video.forced.srt
    #   <basename>.<format>                  video.srt
    #
    # Lang is an ISO-639-1 or 639-2 code. We don't try to fix mislabelled tracks
    # — that is a metadata-agent responsibility.
    module ExternalPickup
      FORMATS = %w[srt ass ssa vtt sub idx sup].freeze

      Sidecar = Struct.new(:path, :format, :language, :forced, :hearing_impaired, keyword_init: true) do
        def title
          parts = []
          parts << language.upcase if language
          parts << 'Forced' if forced
          parts << 'SDH' if hearing_impaired
          parts.empty? ? File.basename(path) : parts.join(' ')
        end
      end

      module_function

      # Port of SubtitleEncoder.GetSubtitleFilePath (cs:1030). Resolves the
      # absolute path of an extracted / sidecar subtitle for the given
      # stream. For internal streams we return the extractor cache path;
      # for external streams we return the sidecar path verbatim.
      def get_subtitle_file_path(stream:, media_source:, cache_root: nil)
        return stream.external_path.to_s if stream.respond_to?(:external_path) && stream.external_path
        return nil unless cache_root
        digest = Digest::SHA1.hexdigest("#{media_source.path}|#{stream.index}")[0, 16]
        File.join(cache_root, 'subs', "#{digest}.vtt")
      end

      # Returns an array of Sidecar records for files alongside `video_path`.
      def discover(video_path)
        return [] if video_path.nil?
        dir = File.dirname(video_path)
        return [] unless File.directory?(dir)
        base = File.basename(video_path, '.*')

        candidates = Dir.children(dir).select do |entry|
          # match: same base name, allowed format, optional `.lang(.forced|.sdh)` segments
          entry.start_with?(base + '.') &&
            FORMATS.include?(entry.split('.').last.downcase)
        end

        candidates.map { |entry| parse(File.join(dir, entry), base) }.compact
      end

      def parse(path, base)
        ext = File.extname(path).delete('.').downcase
        return nil unless FORMATS.include?(ext)

        # Strip basename + leading dot, drop trailing extension.
        rest = File.basename(path, '.' + ext)
        rest = rest[base.length + 1..] if rest.start_with?(base + '.')
        return Sidecar.new(path: path, format: ext, language: nil, forced: false, hearing_impaired: false) if rest.nil? || rest.empty?

        parts  = rest.split('.').map(&:downcase)
        forced = parts.delete('forced') ? true : false
        sdh    = (parts.delete('sdh') || parts.delete('hi') || parts.delete('cc')) ? true : false
        # Anything 2- or 3-letter remaining is treated as the language tag.
        lang   = parts.find { |p| p.size.between?(2, 3) }

        Sidecar.new(path: path, format: ext, language: lang, forced: forced, hearing_impaired: sdh)
      end
    end
  end
end
