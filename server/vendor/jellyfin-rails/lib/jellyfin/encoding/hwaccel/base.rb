module Jellyfin
  module Encoding
    module Hwaccel
      # Common interface every HW accel backend exposes. The EncodingHelper
      # dispatches to the configured backend through this contract.
      module Base
        # Override in each backend.
        def name = raise(NotImplementedError)

        # Return true only if the system actually has the right ffmpeg build +
        # driver / device available. Backends consult MediaEncoder capabilities.
        def available?(_capabilities) = false

        # Return the ffmpeg encoder name for the requested target codec, e.g.
        # 'h264_videotoolbox', or nil if this backend can't encode it.
        def encoder_for(_target_codec, _capabilities) = nil

        # Returns an array of args to splice in *before* the `-i input` to enable
        # HW decode (e.g. -hwaccel videotoolbox). Empty array if not applicable.
        def decode_args(_job, _capabilities) = []

        # Returns the filter graph segment (string) for HDR tonemap / scale on
        # this hardware. Nil if SW fallback should be used.
        def filter_chain(_job, _capabilities) = nil

        # Returns codec-specific args (preset, rc-mode, etc.) for the chosen encoder.
        def encoder_args(_job) = []
      end
    end
  end
end
