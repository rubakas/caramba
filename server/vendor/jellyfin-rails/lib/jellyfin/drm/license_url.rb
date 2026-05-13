module Jellyfin
  module Drm
    # License-URL passthrough. Each DRM system communicates its license URL
    # via a different manifest mechanism:
    #
    #   - DASH (MPD): a <ContentProtection> element with a per-system
    #     `cenc:pssh` payload, plus a `dashif:Laurl` element naming the URL.
    #   - HLS: an `#EXT-X-SESSION-KEY` line per DRM, with `URI=` pointing at
    #     the license endpoint (or a key URI for ClearKey).
    #
    # This module renders the right manifest fragments. The actual license
    # server is pluggable — register an implementation via `Kms.register`.
    module LicenseUrl
      module_function

      # DASH MPD ContentProtection element. Caller embeds this into the MPD
      # <AdaptationSet> or <Representation>.
      def mpd_content_protection(system:, license_url:, pssh_base64:, key_id_hex: nil)
        system_uuid = Pssh::SYSTEM_IDS.fetch(system)
        xml = +%(  <ContentProtection schemeIdUri="urn:uuid:#{system_uuid}" value="#{system}">)
        xml << "\n    <cenc:pssh>#{pssh_base64}</cenc:pssh>"
        xml << "\n    <dashif:Laurl>#{license_url}</dashif:Laurl>" if license_url
        xml << "\n  </ContentProtection>"
        xml
      end

      # HLS session-key line. For ClearKey this points at the raw key bytes;
      # for Widevine/FairPlay it points at the license server endpoint.
      def hls_session_key(system:, license_url:, key_format: nil, iv_hex: nil)
        key_format ||= default_key_format(system)
        attrs = ['METHOD=SAMPLE-AES',
                 %(URI="#{license_url}"),
                 %(KEYFORMAT="#{key_format}"),
                 'KEYFORMATVERSIONS="1"']
        attrs << "IV=0x#{iv_hex}" if iv_hex
        "#EXT-X-SESSION-KEY:#{attrs.join(',')}"
      end

      def default_key_format(system)
        case system
        when :widevine  then 'urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed'
        when :playready then 'com.microsoft.playready'
        when :fairplay  then 'com.apple.streamingkeydelivery'
        when :clearkey  then 'identity'
        end
      end
    end
  end
end
