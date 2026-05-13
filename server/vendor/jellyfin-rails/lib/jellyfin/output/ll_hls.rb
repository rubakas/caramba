module Jellyfin
  module Output
    # Low-Latency HLS (RFC 8216bis). Aims for sub-second glass-to-glass latency
    # for live streams by:
    #
    #   - emitting *partial segments* (`#EXT-X-PART`) every ~200 ms inside a
    #     normal segment, so clients can start playback sooner
    #   - announcing *preload hints* (`#EXT-X-PRELOAD-HINT`) for the next
    #     partial, letting clients prefetch
    #   - servers using HTTP/2 push or blocking playlist reload requests
    #     (`?_HLS_msn=N&_HLS_part=M`) to deliver partials as they're ready
    #
    # ffmpeg has had LL-HLS support since 4.4 via:
    #   -hls_segment_type fmp4
    #   -hls_flags +program_date_time+independent_segments
    #   -hls_fragment_duration <millis>     (fragment = partial)
    #   -hls_part_target <secs>             (partial target duration)
    #
    # This module emits the args; the controller serving the playlist also
    # has to honor `_HLS_msn` / `_HLS_part` query params for blocking reloads.
    module LlHls
      module_function

      # Args for the ffmpeg HLS muxer. `partial_target` is in seconds (typical
      # values: 0.2–0.5). The muxer derives fragment count per segment from
      # segment_length / partial_target.
      def output_args(partial_target: 0.5, segment_length: 4)
        [
          '-hls_segment_type', 'fmp4',
          '-hls_flags', 'program_date_time+independent_segments+append_list',
          '-hls_time', segment_length.to_s,
          '-hls_fragment_duration', (partial_target * 1000).to_i.to_s,
          # Force `EXT-X-PART-INF` and per-part lines in the playlist.
          '-hls_partial_segments', '1',
          # New-style flags name in recent ffmpeg builds — we emit both for
          # forward compat. Unknown flags are ignored.
          '-hls_part_target', format('%.2f', partial_target)
        ]
      end

      # Parses ?_HLS_msn=N&_HLS_part=M from a query-string hash. Returns
      # [msn, part] or [nil, nil] if not present.
      def parse_blocking_hint(query_params)
        msn  = query_params['_HLS_msn']
        part = query_params['_HLS_part']
        [msn&.to_i, part&.to_i]
      end

      # Builds a server-emitted `#EXT-X-SERVER-CONTROL` header announcing
      # capability + `CAN-BLOCK-RELOAD`. Spliced into the per-track playlist.
      def server_control_header(part_hold_back: nil, can_block_reload: true)
        attrs = []
        attrs << "CAN-BLOCK-RELOAD=#{can_block_reload ? 'YES' : 'NO'}"
        attrs << "PART-HOLD-BACK=#{format('%.3f', part_hold_back)}" if part_hold_back
        "#EXT-X-SERVER-CONTROL:#{attrs.join(',')}"
      end

      # Builds the `#EXT-X-PART-INF` line announcing the maximum partial
      # segment duration.
      def part_inf_header(part_target:)
        "#EXT-X-PART-INF:PART-TARGET=#{format('%.3f', part_target)}"
      end

      # Builds an `#EXT-X-PRELOAD-HINT` line pointing to the next partial.
      def preload_hint(uri:, type: 'PART')
        attrs = ["TYPE=#{type}", %(URI="#{uri}")]
        "#EXT-X-PRELOAD-HINT:#{attrs.join(',')}"
      end

      # Renders an `#EXT-X-PART` line.
      def part_line(uri:, duration:, independent: false)
        attrs = ["DURATION=#{format('%.3f', duration)}", %(URI="#{uri}")]
        attrs << 'INDEPENDENT=YES' if independent
        "#EXT-X-PART:#{attrs.join(',')}"
      end
    end
  end
end
