module Jellyfin
  module Encoding
    # HDR10+ dynamic metadata (SMPTE ST.2094-40) passthrough. Distinct from
    # Dolby Vision: HDR10+ uses an SEI message embedded in the HEVC bitstream
    # rather than a separate RPU layer, so passthrough is *almost* free — we
    # just have to tell x265 to emit the SEI as-is.
    #
    # Detection happens via the probe normaliser, which sets
    # `MediaStream#hdr10plus_present` when ffprobe reports a side-data record
    # of type "HDR Dynamic Metadata SMPTE2094-40 (HDR10+)".
    module Hdr10Plus
      module_function

      def present?(stream)
        return false unless stream
        stream.hdr10plus_present == true
      end

      # x265-params fragment that emits the HDR10+ dynamic metadata SEI. Only
      # honoured by x265 builds compiled with --enable-hdr10plus.
      def x265_params(stream)
        return nil unless present?(stream)
        # `dhdr10-info` is the x265 option name (despite the misleading
        # "DHDR10" — Dolby/HDR10 it stands for "Dynamic HDR10+").
        # Without an actual JSON metadata file we still want the SEI flag.
        'hdr-opt=1:dhdr10-opt=1'
      end

      # Returns the per-frame metadata file path if a sidecar JSON exists.
      # Real workflows pre-extract HDR10+ metadata via `hdr10plus_tool extract`
      # and pass the JSON to x265 via `dhdr10-info=<path>`.
      def metadata_file_for(stream, cache_dir:)
        return nil unless present?(stream)
        digest = Digest::SHA1.hexdigest(stream.object_id.to_s)
        path = File.join(cache_dir, "#{digest}.hdr10plus.json")
        File.exist?(path) ? path : nil
      end
    end
  end
end
