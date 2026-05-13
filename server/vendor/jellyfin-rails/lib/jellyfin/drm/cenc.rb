require 'securerandom'

module Jellyfin
  module Drm
    # Common Encryption (ISO/IEC 23001-7). The underlying scheme used by all
    # three major DRMs (Widevine, FairPlay, PlayReady). ffmpeg implements both
    # standard modes:
    #
    #   cenc-aes-ctr — AES-128 in CTR mode, default for DASH + Widevine
    #   cbcs        — AES-128-CBC with sample subsample patterns, required by
    #                  FairPlay and modern Widevine
    #
    # The encryption is purely the ffmpeg side. License-server URLs and the
    # PSSH box that wraps the key ID for the player are built separately.
    module Cenc
      KEY_BYTES = 16
      KID_BYTES = 16

      Material = Struct.new(:key_hex, :kid_hex, :scheme, keyword_init: true) do
        def key_bytes = [key_hex].pack('H*')
        def kid_bytes = [kid_hex].pack('H*')
      end

      module_function

      # Generates a fresh 128-bit content key + 128-bit key ID. The KID is the
      # identifier the player sends to the license server to request the key;
      # the key itself is what ffmpeg uses to encrypt segments.
      def generate(scheme: 'cenc-aes-ctr')
        Material.new(
          key_hex: SecureRandom.hex(KEY_BYTES),
          kid_hex: SecureRandom.hex(KID_BYTES),
          scheme: scheme
        )
      end

      # ffmpeg args to encrypt the output with CENC. Returns [] when material
      # is nil (encryption disabled).
      def output_args(material)
        return [] unless material
        ['-encryption_scheme', material.scheme,
         '-encryption_key', material.key_hex,
         '-encryption_kid', material.kid_hex]
      end
    end
  end
end
