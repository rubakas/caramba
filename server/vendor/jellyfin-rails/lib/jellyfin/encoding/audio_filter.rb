module Jellyfin
  module Encoding
    # Port of EncodingHelper.GetAudioFilterParam (cs:2834). Assembles a single
    # `-af` filter chain string from the per-feature audio filters we already
    # have:
    #
    #   - channel downmix (Audio.downmix_pan)
    #   - loudness normalisation (Audio.loudnorm_filter)
    #   - dynamic range compression (Audio.drc_filter)
    #   - sample-rate conversion (Audio.resampler_filter)
    #
    # The upstream version also handles audio padding and timestamp adjustment
    # which apply only in narrow edge-cases (some PGS subtitle pipelines).
    # Returns nil when no filter applies — caller skips `-af` entirely.
    module AudioFilter
      module_function

      def call(job, encoding_options: nil, capabilities: nil)
        encoding_options ||= job.options
        chain = Jellyfin::Encoding::Audio.filter_chain(job, capabilities: capabilities)
        # filter_chain may already include the downmix + resampler;
        # GetAudioFilterParam also appends the explicit channel-count fixup
        # for asymmetric inputs.
        if encoding_options.respond_to?(:audio_pad_silence) && encoding_options.audio_pad_silence
          chain << 'apad'
        end
        chain.empty? ? nil : chain.join(',')
      end
    end
  end
end
