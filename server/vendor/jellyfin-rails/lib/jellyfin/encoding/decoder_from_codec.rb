module Jellyfin
  module Encoding
    # Port of EncodingHelper.GetDecoderFromCodec (cs:643). Returns the ffmpeg
    # decoder name for a given codec, or nil when the codec is on the
    # "ffmpeg-name-unknown" blocklist (mp2, aac_latm, eac3 in upstream).
    #
    # The upstream variant additionally consults `IMediaEncoder.SupportsDecoder`
    # to verify the binary actually has it; we accept a capabilities object
    # with the same `supports_decoder?` interface.
    module DecoderFromCodec
      # Codecs where ffmpeg's *decoder* name differs from the *codec* name
      # in ways the upstream method explicitly returns nil for. Upstream uses
      # this list as a "skip auto-decoder hint" — ffmpeg picks something else.
      UNMAPPED = %w[mp2 aac_latm eac3].freeze

      module_function

      def for(codec, capabilities: nil)
        return nil if codec.nil? || codec.to_s.empty?
        normalized = codec.to_s.downcase
        return nil if UNMAPPED.include?(normalized)
        return nil if capabilities && capabilities.respond_to?(:supports_decoder?) && !capabilities.supports_decoder?(normalized)
        normalized
      end
    end
  end
end
