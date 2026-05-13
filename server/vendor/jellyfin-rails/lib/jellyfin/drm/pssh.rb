require 'base64'

module Jellyfin
  module Drm
    # Constructs PSSH ("Protection System Specific Header") boxes — the
    # ISOBMFF container that carries DRM-system-specific data inside an mp4 /
    # CMAF segment. Each DRM has its own system ID and a per-system payload.
    #
    # Box structure (ISO/IEC 23001-7 §8.1):
    #
    #   size       4  bytes  big-endian length including header
    #   type       4  bytes  'pssh' (0x70 73 73 68)
    #   version    1  byte   0 or 1
    #   flags      3  bytes  reserved (zeros)
    #   system_id  16 bytes  per-DRM UUID (canonical "drmtype" GUID)
    #   if version=1:
    #     kid_count    4 bytes (big-endian)
    #     kids[]       16 * kid_count bytes
    #   data_size  4  bytes
    #   data       <data_size> bytes  drm-specific payload
    module Pssh
      SYSTEM_IDS = {
        widevine:  'edef8ba9-79d6-4ace-a3c8-27dcd51d21ed',
        playready: '9a04f079-9840-4286-ab92-e65be0885f95',
        fairplay:  '94ce86fb-07ff-4f43-adb8-93d2fa968ca2',
        clearkey:  '1077efec-c0b2-4d02-ace3-3c1e52e2fb4b'
      }.freeze

      module_function

      # Builds a v1 PSSH box. `kids` is an array of 16-byte binary KIDs (NOT
      # hex). `data` is the drm-specific binary payload (may be empty).
      def box(system:, kids:, data: ''.b)
        system_id = uuid_to_bytes(SYSTEM_IDS.fetch(system))
        body  = system_id
        body += [kids.size].pack('N')
        body += kids.join
        body += [data.bytesize].pack('N') + data
        # Header
        header = [0x01].pack('C') + ("\x00" * 3).b
        payload = header + body
        size = 4 + 4 + payload.bytesize # size field + 'pssh' + payload
        [size].pack('N') + 'pssh'.b + payload
      end

      # Base64-encoded PSSH suitable for DASH MPD `<cenc:pssh>` element or HLS
      # `KEYFORMATVERSIONS="1"` URI data: scheme.
      def base64(system:, kids:, data: ''.b)
        Base64.strict_encode64(box(system: system, kids: kids, data: data))
      end

      # Converts "edef8ba9-79d6-4ace-a3c8-27dcd51d21ed" → 16-byte string.
      def uuid_to_bytes(uuid)
        [uuid.delete('-')].pack('H*')
      end
    end
  end
end
