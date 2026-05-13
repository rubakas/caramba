require 'securerandom'
require 'fileutils'
require 'digest'

module Jellyfin
  module Output
    # AES-128 HLS encryption helpers.
    #
    # ffmpeg's hls muxer encrypts segments inline when supplied with a
    # `key_info_file`. The file has three lines:
    #
    #   <key URI as written into the playlist>
    #   <local path to the 16-byte key file ffmpeg should read>
    #   <hex IV (optional, ffmpeg derives one per segment if absent)>
    #
    # We generate the key + IV at session start, write the key-info-file, and
    # serve the raw 16-byte key from a controller endpoint guarded by the
    # session token. Players fetch the key via the URI we wrote into the
    # playlist; the server enforces auth on that endpoint.
    #
    # For SAMPLE-AES (Apple's preferred mode) the file format is identical;
    # ffmpeg switches via `-hls_enc_iv` semantics + the muxer `-hls_enc 1`
    # plus container support (currently fmp4 + Apple's hls.js).
    module HlsEncryption
      KEY_BYTES = 16

      Material = Struct.new(:key_path, :info_path, :key_uri, :key_hex, :iv_hex,
                            keyword_init: true)

      module_function

      # Generates fresh material and writes the key-info-file. `key_uri` is the
      # URL the *player* will fetch the key from; we write it verbatim into
      # the .m3u8.
      def generate!(session_dir:, key_uri:)
        FileUtils.mkdir_p(session_dir)
        key_bytes = SecureRandom.random_bytes(KEY_BYTES)
        iv_bytes  = SecureRandom.random_bytes(KEY_BYTES)

        key_path  = File.join(session_dir, 'enc.key')
        info_path = File.join(session_dir, 'enc.keyinfo')
        File.binwrite(key_path, key_bytes)
        File.chmod(0o600, key_path)

        info_lines = [key_uri, key_path, iv_bytes.unpack1('H*')]
        File.write(info_path, info_lines.join("\n") + "\n")

        Material.new(
          key_path: key_path,
          info_path: info_path,
          key_uri: key_uri,
          key_hex: key_bytes.unpack1('H*'),
          iv_hex: iv_bytes.unpack1('H*')
        )
      end

      # Args to splice into the ffmpeg HLS output. Returns [] when material
      # is nil (encryption disabled).
      def output_args(material)
        return [] unless material
        ['-hls_enc', '1', '-hls_enc_key_url', material.key_uri,
         '-hls_key_info_file', material.info_path]
      end

      def read_key(key_path)
        return nil unless File.exist?(key_path)
        File.binread(key_path)
      end
    end
  end
end
