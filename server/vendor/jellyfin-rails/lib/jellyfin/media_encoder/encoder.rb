require 'jellyfin/media_encoder/encoder_validator'

module Jellyfin
  module MediaEncoder
    # Lazy facade over the configured ffmpeg binary. Caches capabilities probe
    # for the lifetime of the process — restart Rails to re-probe after upgrading ffmpeg.
    class Encoder
      class << self
        def capabilities
          @capabilities ||= EncoderValidator.new(Jellyfin::Rails.configuration.ffmpeg_path).probe
        end

        def reset!
          @capabilities = nil
        end
      end
    end
  end
end
