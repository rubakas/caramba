module Jellyfin
  module Output
    # Builds the HLS master playlist string from scratch, mirroring upstream
    # Jellyfin's `DynamicHlsHelper.GetMasterPlaylistInternal` +
    # `AppendPlaylist` + `AddSubtitles` + `AddTrickplay`.
    #
    # Upstream pattern: the master playlist is HAND-BUILT, not served from
    # ffmpeg's output. ffmpeg emits the *variant* playlist (main.m3u8 / live.m3u8)
    # which lists segments; the master playlist references that variant and
    # adds rendition groups for subtitles / audio / closed-captions / trickplay.
    #
    # Ports DynamicHlsHelper.cs:148-343 (the GetMasterPlaylistInternal body)
    # and the AppendPlaylist / AddSubtitles / AddTrickplay helpers.
    module MasterPlaylistBuilder
      module_function

      # Builds the master playlist string. `job` is a TranscodingJob; the
      # `:variant_url` argument is the URL the player should fetch the
      # *variant* playlist from (typically `main.m3u8` or `live.m3u8`).
      #
      # `subtitle_tracks` / `trickplay_resolutions` are optional arrays of
      # rendition descriptors; pass nil/[] to omit those groups entirely.
      def build(job:, variant_url:, total_bitrate:, video_stream: nil, audio_stream: nil,
                subtitle_tracks: [], trickplay_resolutions: [],
                audio_renditions: [], has_closed_captions: false,
                is_live_stream: false)
        # Mirror DynamicHlsHelper.cs:148 — builder starts with "#EXTM3U".
        lines = ['#EXTM3U']

        # AddSubtitles equivalent: emit #EXT-X-MEDIA TYPE=SUBTITLES lines BEFORE
        # the stream-inf so the variant can reference the group.
        subtitle_group = subtitle_tracks.any? ? 'subs' : nil
        if subtitle_group
          lines.concat(subtitle_media_lines(subtitle_tracks))
        end

        # #EXT-X-MEDIA TYPE=AUDIO renditions (separate-audio profile).
        audio_group = audio_renditions.any? ? 'audio' : nil
        if audio_group
          lines.concat(Jellyfin::Output::AudioRendition.media_lines(audio_renditions))
        end

        # Closed-caption announcement (in-band; no URI).
        cc_group = has_closed_captions ? 'cc' : nil
        if cc_group
          lines << Jellyfin::Subtitle::ClosedCaptions.master_media_line(
            instream: 'CC1', name: 'English', language: 'en', default: true
          )
        end

        # AppendPlaylist equivalent: one #EXT-X-STREAM-INF + variant URL.
        lines.concat(append_playlist(
          variant_url: variant_url,
          total_bitrate: total_bitrate,
          video_stream: video_stream,
          audio_stream: audio_stream,
          subtitle_group: subtitle_group,
          audio_group: audio_group,
          cc_group: cc_group
        ))

        # AddTrickplay equivalent: one #EXT-X-IMAGE-STREAM-INF per resolution.
        # Upstream guards this with `!isLiveStream && state.VideoRequest.EnableTrickplay`.
        if !is_live_stream && trickplay_resolutions.any?
          lines.concat(trickplay_lines(trickplay_resolutions))
        end

        lines.join("\n") + "\n"
      end

      # Renders the #EXT-X-STREAM-INF line + variant URL. Mirrors
      # `DynamicHlsHelper.AppendPlaylist` (lines 345-394 upstream).
      def append_playlist(variant_url:, total_bitrate:, video_stream:, audio_stream:,
                          subtitle_group:, audio_group:, cc_group:)
        attrs = ["BANDWIDTH=#{total_bitrate}",
                 "AVERAGE-BANDWIDTH=#{total_bitrate}"]

        # AppendPlaylistVideoRangeField (DynamicHlsHelper.cs:442)
        if video_stream
          range = upstream_video_range(video_stream)
          attrs << "VIDEO-RANGE=#{range}" if range
        end

        # AppendPlaylistCodecsField (DynamicHlsHelper.cs:486)
        if video_stream
          codec_str = Jellyfin::Output::CodecString.for(
            video_codec: video_stream.codec || 'h264',
            audio_codec: audio_stream&.codec || 'aac',
            profile: video_stream.profile,
            level: (video_stream.level.to_f / 10.0 if video_stream.level),
            audio_channels: audio_stream&.channels || 2
          )
          attrs << %(CODECS="#{codec_str}") if codec_str && !codec_str.empty?
        end

        # AppendPlaylistResolutionField (DynamicHlsHelper.cs:601)
        if video_stream && video_stream.width && video_stream.height
          attrs << "RESOLUTION=#{video_stream.width}x#{video_stream.height}"
        end

        # AppendPlaylistFramerateField (DynamicHlsHelper.cs:618)
        if video_stream && video_stream.frame_rate
          attrs << "FRAME-RATE=#{format('%.3f', video_stream.frame_rate)}"
        end

        # Rendition group references.
        attrs << %(SUBTITLES="#{subtitle_group}") if subtitle_group
        attrs << %(AUDIO="#{audio_group}")        if audio_group
        attrs << %(CLOSED-CAPTIONS="#{cc_group}") if cc_group

        ["#EXT-X-STREAM-INF:#{attrs.join(',')}", variant_url]
      end

      # AddSubtitles equivalent (DynamicHlsHelper.cs:674).
      def subtitle_media_lines(tracks)
        selected_index = tracks.find { |t| t[:selected] }&.dig(:stream_index)
        tracks.map do |t|
          is_default = (selected_index && selected_index == t[:stream_index]) || t[:default]
          is_forced  = t[:forced]
          name       = t[:name] || t[:language] || 'Unknown'
          language   = t[:language] || 'Unknown'
          attrs = ['TYPE=SUBTITLES',
                   %(GROUP-ID="subs"),
                   %(NAME="#{name}"),
                   "DEFAULT=#{is_default ? 'YES' : 'NO'}",
                   "FORCED=#{is_forced ? 'YES' : 'NO'}",
                   'AUTOSELECT=YES',
                   %(URI="#{t.fetch(:uri)}"),
                   %(LANGUAGE="#{language}")]
          "#EXT-X-MEDIA:#{attrs.join(',')}"
        end
      end

      # AddTrickplay equivalent (DynamicHlsHelper.cs:719).
      # Each resolution is a hash: { width:, height:, bandwidth:, uri: }.
      def trickplay_lines(resolutions)
        resolutions.map do |r|
          %(#EXT-X-IMAGE-STREAM-INF:BANDWIDTH=#{r[:bandwidth]},RESOLUTION=#{r[:width]}x#{r[:height]},CODECS="jpeg",URI="#{r[:uri]}")
        end
      end

      # upstream VideoRange enum → master-playlist string. Mirrors
      # AppendPlaylistVideoRangeField (DynamicHlsHelper.cs:442).
      def upstream_video_range(video_stream)
        case video_stream.video_range_type.to_s.upcase
        when 'HDR10', 'HLG'        then 'PQ'
        when 'HDR10PLUS', 'DOVI'   then 'PQ'
        else                            'SDR'
        end
      end
    end
  end
end
