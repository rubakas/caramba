module Jellyfin
  module Encoding
    # WebVTT subtitle track generation for HLS. The master playlist references
    # this as `#EXT-X-MEDIA TYPE=SUBTITLES`, so the player can show a native
    # caption picker.
    #
    # Two phases:
    #   1) extract — pre-render each subtitle stream to a sidecar .vtt file
    #      (one .vtt per stream, segmented into N-second chunks for HLS).
    #   2) playlist — emit the `#EXT-X-MEDIA` lines for the master playlist
    #      and the per-track playlist that lists the .vtt segments.
    module WebvttSubs
      module_function

      # Builds the per-track HLS playlist for a webvtt subtitle. Returns the
      # playlist text (one m3u8 listing the .vtt segments).
      def per_track_playlist(segments:, segment_length:, total_duration:)
        lines = ['#EXTM3U', '#EXT-X-VERSION:6',
                 "#EXT-X-TARGETDURATION:#{segment_length}",
                 '#EXT-X-PLAYLIST-TYPE:VOD']
        elapsed = 0
        segments.each_with_index do |seg_uri, i|
          # The final segment is shorter than `segment_length`; clamp.
          dur = [segment_length, total_duration - elapsed].min
          lines << "#EXTINF:#{format('%.3f', dur)},"
          lines << seg_uri
          elapsed += dur
        end
        lines << '#EXT-X-ENDLIST'
        lines.join("\n")
      end

      # `#EXT-X-MEDIA` directives for the master playlist. Each `track` is a
      # hash: { uri:, name:, language:, default:, forced: }.
      def master_media_lines(tracks)
        tracks.map do |t|
          attrs = ['TYPE=SUBTITLES', 'GROUP-ID="subs"',
                   %(NAME="#{t.fetch(:name)}"),
                   %(LANGUAGE="#{t[:language] || 'und'}"),
                   "DEFAULT=#{t[:default] ? 'YES' : 'NO'}",
                   "FORCED=#{t[:forced] ? 'YES' : 'NO'}",
                   "AUTOSELECT=#{t[:default] ? 'YES' : 'NO'}",
                   %(URI="#{t.fetch(:uri)}")]
          "#EXT-X-MEDIA:#{attrs.join(',')}"
        end
      end

      # Builds an ffmpeg args block to extract a single subtitle stream to a
      # WebVTT file. Used by the per-job webvtt extractor.
      def extract_args(input_path:, stream_index:, output_path:, start: 0, duration: nil)
        args = ['-y', '-loglevel', 'error', '-ss', start.to_s]
        args.concat(['-t', duration.to_s]) if duration
        args.concat([
          '-i', input_path,
          '-map', "0:s:#{stream_index}",
          '-c:s', 'webvtt',
          '-f', 'webvtt',
          output_path
        ])
        args
      end

      # Emits the STREAM-INF SUBTITLES attribute that links variants to the
      # subtitle group. Pass this into the existing master_playlist builder.
      def stream_inf_subtitle_attr
        'SUBTITLES="subs"'
      end
    end
  end
end
