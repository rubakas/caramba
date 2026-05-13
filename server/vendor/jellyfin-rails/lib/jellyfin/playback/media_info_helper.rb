require 'ipaddr'

module Jellyfin
  module Playback
    # Port of MediaInfoHelper.cs (subset that lives in the transcoding/HLS
    # layer). The upstream class has methods that depend on User/Permission
    # entities we don't model; this port covers the device-profile +
    # bitrate-cap + media-source sorting logic which is purely a stream
    # selection concern.
    module MediaInfoHelper
      # Default RemoteClientBitrateLimit when no per-user value is configured.
      # Upstream reads ServerConfiguration.RemoteClientBitrateLimit; we accept
      # it as an argument so callers can plug in their own config source.
      DEFAULT_REMOTE_CLIENT_BITRATE_LIMIT = 0

      # CIDRs treated as "local network". Mirrors NetworkManager.IsInLocalNetwork
      # at a coarse level — RFC1918 + loopback. Production deployments can
      # override by reassigning `LOCAL_NETWORKS` before the first request.
      LOCAL_NETWORKS = [
        IPAddr.new('10.0.0.0/8'),
        IPAddr.new('172.16.0.0/12'),
        IPAddr.new('192.168.0.0/16'),
        IPAddr.new('127.0.0.0/8'),
        IPAddr.new('::1/128'),
        IPAddr.new('fd00::/8')
      ].freeze

      module_function

      # Port of MediaInfoHelper.GetMaxBitrate (cs:495). Upstream picks the
      # tighter of the client-supplied max and the server's
      # `RemoteClientBitrateLimit`, but ONLY when the client is on a remote
      # IP. Local clients are uncapped.
      def get_max_bitrate(client_max_bitrate:,
                          remote_client_bitrate_limit: DEFAULT_REMOTE_CLIENT_BITRATE_LIMIT,
                          ip_address: nil)
        max_bitrate = client_max_bitrate
        return max_bitrate unless remote_client_bitrate_limit.to_i.positive?
        return max_bitrate if in_local_network?(ip_address)

        if max_bitrate.nil?
          remote_client_bitrate_limit
        else
          [max_bitrate, remote_client_bitrate_limit].min
        end
      end

      def in_local_network?(ip_address)
        return true if ip_address.nil? || ip_address.to_s.empty?
        addr = IPAddr.new(ip_address.to_s)
        LOCAL_NETWORKS.any? { |net| net.include?(addr) }
      rescue IPAddr::InvalidAddressError
        false
      end

      # Port of MediaInfoHelper.SortMediaSources (cs:354). Re-orders an array
      # of media-source-like hashes by playback desirability:
      #
      #   1. Direct play of a local file
      #   2. Anything else that supports direct play OR direct stream
      #   3. Any file:// protocol source
      #   4. Sources whose bitrate fits under `max_bitrate`
      #   5. Original order (stable secondary sort)
      def sort_media_sources(sources, max_bitrate: nil)
        original = sources.dup
        sources.sort_by.with_index do |s, idx|
          [
            (supports_direct_play?(s) && file_protocol?(s)) ? 0 : 1,
            (supports_direct_play?(s) || supports_direct_stream?(s)) ? 0 : 1,
            file_protocol?(s) ? 0 : 1,
            bitrate_fits?(s, max_bitrate),
            original.index(s) || idx
          ]
        end
      end

      # Port of MediaInfoHelper.SetDeviceSpecificData (cs:170). Adapts the
      # upstream method to our pure-Ruby model: we don't have a User entity,
      # so the permission-gated branches are dropped. The remaining work is:
      #
      #   - apply the user's enable_direct_play / enable_direct_stream toggles
      #   - apply the bitrate cap
      #   - call Decision.call to pick the play method
      #   - stamp the result back onto the source
      def set_device_specific_data(media_source:, profile:,
                                   max_bitrate: nil,
                                   start_time_ticks: 0,
                                   audio_stream_index: nil,
                                   subtitle_stream_index: nil,
                                   max_audio_channels: nil,
                                   play_session_id: nil,
                                   enable_direct_play: true,
                                   enable_direct_stream: true,
                                   enable_transcoding: true,
                                   allow_video_stream_copy: true,
                                   allow_audio_stream_copy: true,
                                   ip_address: nil,
                                   remote_client_bitrate_limit: DEFAULT_REMOTE_CLIENT_BITRATE_LIMIT)
        # Mirror cs:217-227 — initial flags before the play-method decision.
        media_source.respond_to?(:supports_direct_play=) && media_source.supports_direct_play = false unless enable_direct_play
        media_source.respond_to?(:supports_direct_stream=) && media_source.supports_direct_stream = false if !enable_direct_stream || !allow_video_stream_copy
        media_source.respond_to?(:supports_transcoding=) && media_source.supports_transcoding = false unless enable_transcoding

        # cs:247: cap the bitrate by per-user / network rules.
        effective_max = get_max_bitrate(client_max_bitrate: max_bitrate,
                                        remote_client_bitrate_limit: remote_client_bitrate_limit,
                                        ip_address: ip_address)

        # cs:256: route through the Decision module — Ruby equivalent of
        # StreamBuilder.GetOptimalVideoStream / GetOptimalAudioStream.
        result = Decision.call(
          media_source: media_source, profile: profile,
          requested: {
            max_bitrate: effective_max,
            audio_track: audio_stream_index,
            subtitle_track: subtitle_stream_index,
            max_audio_channels: max_audio_channels
          }
        )

        {
          mode: result.mode, container: result.container, reasons: result.reasons,
          max_bitrate: effective_max, play_session_id: play_session_id,
          start_time_ticks: start_time_ticks
        }
      end

      # Helpers that work both with our MediaSourceInfo and with plain hashes.
      def supports_direct_play?(s)
        return s.supports_direct_play if s.respond_to?(:supports_direct_play)
        s.is_a?(Hash) ? !!s[:supports_direct_play] : false
      end

      def supports_direct_stream?(s)
        return s.supports_direct_stream if s.respond_to?(:supports_direct_stream)
        s.is_a?(Hash) ? !!s[:supports_direct_stream] : false
      end

      def file_protocol?(s)
        proto = s.respond_to?(:protocol) ? s.protocol : (s.is_a?(Hash) ? s[:protocol] : nil)
        proto.to_s.casecmp('file').zero?
      end

      def bitrate_fits?(s, max_bitrate)
        return 1 unless max_bitrate
        bitrate = s.respond_to?(:bit_rate) ? s.bit_rate : (s.is_a?(Hash) ? s[:bit_rate] : nil)
        return 1 unless bitrate
        bitrate <= max_bitrate ? 0 : 2
      end
    end
  end
end
