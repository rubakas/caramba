module Jellyfin
  module MediaEncoder
    # Ports of MediaEncoder.CanEncodeToAudioCodec (cs:394) and
    # CanEncodeToSubtitleCodec (cs:408). Each consults the capabilities
    # struct's encoder list, normalising codec aliases to the actual ffmpeg
    # encoder name first (opus → libopus, mp3 → libmp3lame).
    module CodecCapabilities
      # Codec alias → ffmpeg encoder name. Mirrors upstream cs:396-403.
      AUDIO_ALIASES = {
        'opus' => 'libopus',
        'mp3'  => 'libmp3lame'
      }.freeze

      module_function

      # Port of CanEncodeToAudioCodec (cs:394).
      def can_encode_to_audio_codec?(codec, capabilities:)
        return false if codec.nil? || codec.to_s.empty?
        return false unless capabilities.respond_to?(:supports_encoder?)
        normalized = AUDIO_ALIASES.fetch(codec.to_s.downcase, codec.to_s)
        capabilities.supports_encoder?(normalized)
      end

      # Port of CanEncodeToSubtitleCodec (cs:408). Upstream returns `true`
      # unconditionally (with a TODO comment). We mirror that exactly — the
      # method exists so callers can future-proof against a tighter check
      # without rewriting their call sites.
      def can_encode_to_subtitle_codec?(_codec, capabilities: nil)
        true
      end
    end
  end
end
