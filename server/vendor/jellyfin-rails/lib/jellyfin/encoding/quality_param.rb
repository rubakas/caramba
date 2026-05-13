module Jellyfin
  module Encoding
    # Port of EncodingHelper.GetVideoQualityParam (cs:2037). The upstream
    # method picks per-encoder quality args (CRF / QP / preset) given the
    # encoder name + encoding options + default preset.
    #
    # Our existing `Quality.for(job, encoder)` returns most of these; this
    # module fills the remaining gap by dispatching to the same producer but
    # with the upstream's signature shape so callers porting C# code can use
    # the familiar entry point.
    module QualityParam
      module_function

      def call(job:, video_encoder:, encoding_options: nil, default_preset: nil)
        encoding_options ||= job.options
        # Allow the caller to override the preset; mirrors upstream's
        # `defaultPreset` arg which is applied when EncodingOptions doesn't
        # specify one.
        if default_preset && (encoding_options.encoder_preset.nil? || encoding_options.encoder_preset.to_s.empty?)
          encoding_options.encoder_preset = default_preset.to_s
        end
        # Dispatch to our per-encoder Quality module. The shape of the args
        # returned (`['-preset', x, '-profile:v', y, …]`) matches what
        # upstream's GetVideoQualityParam produces as a flat string.
        Jellyfin::Encoding::Quality.for(job, video_encoder)
      end
    end
  end
end
