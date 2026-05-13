module Jellyfin
  module Subtitle
    # CEA-608 / CEA-708 closed-caption detection. These captions are NOT
    # carried as a separate subtitle stream — they're embedded inside the
    # video bitstream as user-data SEI messages (h264/hevc) or
    # picture-user-data (mpeg2). ffprobe surfaces their presence via the
    # video stream's `closed_captions` field (mpeg2) and via side-data on
    # h264/hevc streams.
    #
    # When detected, we expose them as a virtual subtitle track that the
    # client can request burned in or delivered as a separate caption track
    # (HLS CLOSED-CAPTIONS group).
    module ClosedCaptions
      module_function

      # Returns true if the video stream advertises closed captions.
      def present?(video_stream)
        return false unless video_stream
        # mpeg2 sets `closed_captions` directly on the stream.
        return true if video_stream.respond_to?(:closed_captions) && video_stream.closed_captions.to_i.positive?
        # h264 / hevc embed CEA-608 in SEI user_data_registered_itu_t_t35.
        # ffprobe tags such streams with `has_closed_captions=1` in newer
        # builds and via the side_data list otherwise. Probe normaliser surfaces
        # this through a virtual flag on the stream.
        video_stream.respond_to?(:has_closed_captions) && video_stream.has_closed_captions
      end

      # Builds the `#EXT-X-MEDIA TYPE=CLOSED-CAPTIONS` line. Unlike subtitles,
      # closed captions are IN-BAND so the entry has NO URI — instead it
      # carries an INSTREAM-ID of CC1..CC4 (CEA-608) or SERVICE1..SERVICE63
      # (CEA-708).
      def master_media_line(instream: 'CC1', name: 'English', language: 'en', default: true)
        attrs = ['TYPE=CLOSED-CAPTIONS',
                 %(GROUP-ID="cc"),
                 %(NAME="#{name}"),
                 %(LANGUAGE="#{language}"),
                 "DEFAULT=#{default ? 'YES' : 'NO'}",
                 "AUTOSELECT=#{default ? 'YES' : 'NO'}",
                 %(INSTREAM-ID="#{instream}")]
        "#EXT-X-MEDIA:#{attrs.join(',')}"
      end

      # Variant `STREAM-INF` attribute referencing the closed-caption group.
      def stream_inf_cc_attr(group: 'cc')
        %(CLOSED-CAPTIONS="#{group}")
      end

      # ffmpeg flag to preserve CC data when transcoding. Without `-a53cc 1`
      # the SEI user-data is stripped during re-encode.
      def preserve_args
        ['-a53cc', '1']
      end
    end
  end
end
