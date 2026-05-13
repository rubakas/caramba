module Jellyfin
  module Output
    # `#EXT-X-MEDIA TYPE=AUDIO` rendition group for HLS master playlists.
    #
    # When a source has multiple audio tracks (different languages, commentary,
    # describer track) we expose each as a separate AUDIO rendition. The video
    # variants then reference the group via `AUDIO="group-id"` on the
    # `#EXT-X-STREAM-INF` line.
    #
    # Two valid layouts:
    #   - "muxed-audio" variants — each video variant ALSO contains audio.
    #     The AUDIO rendition is INSTREAM with no URI; player switches by
    #     re-fetching the same variant.
    #   - "separate-audio" variants — video-only stream + per-language audio
    #     playlists with URI. Cheapest server-side and what we emit here.
    module AudioRendition
      module_function

      # Builds the `#EXT-X-MEDIA` lines. Each `track` is a hash:
      #   { uri:, name:, language:, default:, channels:, group: }
      def media_lines(tracks)
        tracks.map do |t|
          group = t[:group] || 'audio'
          attrs = ['TYPE=AUDIO',
                   %(GROUP-ID="#{group}"),
                   %(NAME="#{t.fetch(:name)}"),
                   %(LANGUAGE="#{t[:language] || 'und'}"),
                   "DEFAULT=#{t[:default] ? 'YES' : 'NO'}",
                   "AUTOSELECT=#{t[:default] ? 'YES' : 'NO'}"]
          attrs << %(CHANNELS="#{t[:channels]}") if t[:channels]
          attrs << %(URI="#{t.fetch(:uri)}")
          "#EXT-X-MEDIA:#{attrs.join(',')}"
        end
      end

      # Attribute to splice into the variant's `#EXT-X-STREAM-INF` line so the
      # player joins variant + audio.
      def stream_inf_audio_attr(group: 'audio')
        %(AUDIO="#{group}")
      end
    end
  end
end
