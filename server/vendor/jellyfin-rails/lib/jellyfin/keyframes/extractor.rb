require 'jellyfin/keyframes/cache'
require 'jellyfin/keyframes/matroska_extractor'

module Jellyfin
  module Keyframes
    # Front door for keyframe extraction. Currently only MKV files —
    # which is the case the player most needs (HEVC rips, where every
    # other container ships the file in a form we can already direct-
    # play). Mirrors upstream's filter to metadata-based extractors
    # only (DynamicHlsPlaylistGenerator.cs:30) — we skip ffprobe-based
    # packet scanning since it would block /variant.m3u8 for tens of
    # seconds on the first watch of a new file.
    module Extractor
      module_function

      def for(path)
        Cache.fetch(path) { extract(path) }
      end

      def extract(path)
        return nil unless path
        return nil unless File.extname(path).to_s.casecmp?('.mkv')
        MatroskaExtractor.extract(path)
      end
    end
  end
end
