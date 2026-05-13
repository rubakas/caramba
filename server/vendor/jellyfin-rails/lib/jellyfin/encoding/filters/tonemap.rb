module Jellyfin
  module Encoding
    module Filters
      # Software HDR→SDR tonemap chain.
      #
      # Mirrors EncodingHelper.cs lines 691-740: prefer `tonemapx` (jellyfin-ffmpeg
      # patch), fall back to `zscale`+`tonemap`+`format` chain, finally to a SW
      # `tonemap` filter only. Returns nil if not applicable.
      module Tonemap
        module_function

        def build(job, capabilities)
          return nil unless job.hdr_input?
          return nil unless job.options.enable_tonemapping

          peak = job.options.tonemapping_peak

          if capabilities.supports_filter?('tonemapx') && job.video_stream.video_range_type.to_s != 'DOVI'
            return "tonemapx=tonemap=#{job.options.tonemapping_algorithm}:desat=0:peak=#{peak}:" \
                   't=bt709:m=bt709:p=bt709:format=yuv420p:range=full'
          end

          if capabilities.supports_filter?('zscale') && job.video_stream.video_range_type.to_s != 'DOVI'
            return "zscale=t=linear:npl=#{peak},format=gbrpf32le," \
                   'zscale=p=bt709,' \
                   "tonemap=tonemap=#{job.options.tonemapping_algorithm}:desat=0:peak=#{peak}," \
                   'zscale=t=bt709:m=bt709:out_range=full,format=yuv420p'
          end

          # Bare-bones SW fallback when neither tonemapx nor zscale is available.
          "tonemap=tonemap=#{job.options.tonemapping_algorithm}:desat=0:peak=#{peak},format=yuv420p"
        end
      end
    end
  end
end
