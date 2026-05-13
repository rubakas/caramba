module Jellyfin
  module Encoding
    # Ports the colour-property override helpers:
    #
    #   - GetOverwriteColorPropertiesParam (cs:6281) — dispatcher
    #   - GetInputHdrParam (cs:6291)                 — input-side HDR setparams
    #   - GetOutputSdrParam (cs:6303)                — output-side SDR setparams
    #
    # Used when tone-mapping changes the colour space: ffmpeg has no way to
    # propagate the new colour properties end-to-end, so we have to set them
    # explicitly with the `setparams` filter on the input (HDR) and output
    # (SDR) sides of the chain.
    module ColorPropsOverride
      module_function

      # Port of GetOverwriteColorPropertiesParam (cs:6281). Picks the input
      # HDR setparams when tone-mapping is active, otherwise the output SDR
      # one.
      def call(job:, tonemap_available:)
        return input_hdr_param(job.video_stream&.color_transfer) if tonemap_available
        output_sdr_param(job.options.respond_to?(:tonemapping_range) ? job.options.tonemapping_range : nil)
      end

      # Port of GetInputHdrParam (cs:6291). HLG vs HDR10.
      def input_hdr_param(color_transfer)
        if color_transfer.to_s.casecmp('arib-std-b67').zero?
          # HLG
          'setparams=color_primaries=bt2020:color_trc=arib-std-b67:colorspace=bt2020nc'
        else
          # HDR10 (SMPTE 2084 PQ)
          'setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc'
        end
      end

      # Port of GetOutputSdrParam (cs:6303). Optional range argument controls
      # whether tone-mapped output is treated as full or TV range.
      def output_sdr_param(tonemapping_range = nil)
        base = 'setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709'
        return base if tonemapping_range.nil? || tonemapping_range.to_s.empty?
        case tonemapping_range.to_s.downcase
        when 'tv'   then "#{base}:range=tv"
        when 'pc', 'full' then "#{base}:range=pc"
        else base
        end
      end
    end
  end
end
