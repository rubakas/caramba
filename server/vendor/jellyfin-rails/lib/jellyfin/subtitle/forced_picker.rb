module Jellyfin
  module Subtitle
    # Forced-sub selection. Mirrors the logic in EncodingHelper.cs that picks a
    # subtitle track when the user has "Always show forced subtitles" enabled:
    # use the forced track in the audio's language, fall back to any forced
    # track, fall back to nil (no burn).
    module ForcedPicker
      module_function

      # `streams` is the full subtitle stream list. `audio_lang` is an ISO code.
      def choose(streams, audio_lang: nil)
        return nil if streams.nil? || streams.empty?
        same_lang = streams.select { |s| s.is_forced && lang_match?(s.language, audio_lang) }
        return same_lang.first if same_lang.any?
        streams.find(&:is_forced)
      end

      def lang_match?(a, b)
        return false if a.nil? || b.nil?
        a.to_s.downcase[0, 2] == b.to_s.downcase[0, 2]
      end
    end
  end
end
