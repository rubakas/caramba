module Jellyfin
  module Output
    # HLS (HTTP Live Streaming) output writer. Supports two segment formats:
    #   :mpegts - classic .ts segments, broadest compatibility
    #   :fmp4   - fragmented MP4 segments, smaller overhead + DASH-compatible (CMAF)
    #
    # The fmp4 variant is what Jellyfin Web defaults to for modern browsers
    # because it allows the same encoded bytes to serve both HLS and DASH
    # clients (Common Media Application Format / RFC 8216bis).
    module Hls
      module_function

      def output_args(playlist_path:, segment_template:, segment_length:, segment_format: :mpegts,
                      init_segment_path: nil, playlist_type: 'event', flags: nil)
        flags ||= default_flags(segment_format)

        args = [
          '-f', 'hls',
          '-hls_time', segment_length.to_s,
          '-hls_playlist_type', playlist_type,
          '-hls_flags', flags,
          '-hls_segment_type', segment_type(segment_format),
          '-hls_segment_filename', segment_template
        ]
        # fMP4 requires a separate init segment that holds moov/codec metadata.
        # Without it, players can't start the very first segment.
        if segment_format == :fmp4 && init_segment_path
          args.concat(['-hls_fmp4_init_filename', File.basename(init_segment_path)])
        end
        args << playlist_path
        args
      end

      def segment_type(format)
        case format
        when :fmp4 then 'fmp4'
        else            'mpegts'
        end
      end

      def default_flags(format)
        base = %w[independent_segments temp_file]
        # delete_segments only makes sense for live profiles; we use event playlists
        # for VOD which keeps every segment around for seek.
        base << 'append_list' if format == :fmp4
        base.join('+')
      end

      # Builds a master playlist string referencing multiple variant playlists.
      # `variants` is an array of:
      #   { uri:, bandwidth:, codecs:, resolution:, name: }
      def master_playlist(variants:)
        lines = ['#EXTM3U', '#EXT-X-VERSION:7', '']
        variants.each do |v|
          attrs = ["BANDWIDTH=#{v.fetch(:bandwidth).to_i}"]
          attrs << %(CODECS="#{v[:codecs]}") if v[:codecs]
          attrs << %(RESOLUTION=#{v[:resolution]}) if v[:resolution]
          attrs << %(NAME="#{v[:name]}") if v[:name]
          lines << "#EXT-X-STREAM-INF:#{attrs.join(',')}"
          lines << v.fetch(:uri)
          lines << ''
        end
        lines.join("\n")
      end

      # I-frame-only trickplay playlist. Players use this when the user is
      # scrubbing — they fetch only keyframes for a fast preview.
      def iframe_playlist(variants:)
        lines = ['#EXTM3U', '#EXT-X-VERSION:7', '']
        variants.each do |v|
          attrs = ["BANDWIDTH=#{v.fetch(:bandwidth).to_i}",
                   %(URI="#{v.fetch(:uri)}")]
          attrs << %(CODECS="#{v[:codecs]}") if v[:codecs]
          attrs << %(RESOLUTION=#{v[:resolution]}) if v[:resolution]
          lines << "#EXT-X-I-FRAME-STREAM-INF:#{attrs.join(',')}"
        end
        lines.join("\n")
      end
    end
  end
end
