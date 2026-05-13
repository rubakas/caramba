module Jellyfin
  module Encoding
    module Hwaccel
      # Port of EncodingHelper.cs:6195 dispatch — picks the right per-vendor
      # filter chain for the configured hardware acceleration type.
      #
      # Upstream's methods return a tuple `(MainFilters, SubFilters,
      # OverlayFilters)`. We mirror that shape so callers porting C# can
      # consume it directly. `MainFilters` is the video processing chain
      # (scale / tonemap), `SubFilters` is the subtitle-overlay leg for
      # graphical subs, `OverlayFilters` is the final overlay-positioning
      # leg.
      module FilterChain
        Chain = Struct.new(:main_filters, :sub_filters, :overlay_filters, keyword_init: true)

        module_function

        # Dispatcher mirroring EncodingHelper.cs:6195. Returns a Chain struct
        # whose individual lists may be empty.
        def for(accel_type:, job:, vid_encoder:, capabilities:)
          backend =
            case accel_type.to_sym
            when :amf          then Jellyfin::Encoding::Hwaccel::Amf
            when :qsv          then Jellyfin::Encoding::Hwaccel::Qsv
            when :nvenc        then Jellyfin::Encoding::Hwaccel::Nvenc
            when :vaapi        then Jellyfin::Encoding::Hwaccel::Vaapi
            when :videotoolbox then Jellyfin::Encoding::Hwaccel::Videotoolbox
            when :rkmpp        then Jellyfin::Encoding::Hwaccel::Rkmpp
            end

          if backend.nil? || !backend.available?(capabilities)
            return software_chain(job)
          end

          main = backend.filter_chain(job, capabilities).to_s
          Chain.new(
            main_filters: main.empty? ? [] : main.split(','),
            sub_filters: subtitle_overlay_filters(job, backend.name),
            overlay_filters: []
          )
        end

        # Mirrors GetSwVidFilterChain (cs:3777). The SW path uses our existing
        # EncodingHelper#filter_chain output as the main filter list.
        def software_chain(job)
          helper = Jellyfin::Encoding::EncodingHelper.new(nil)
          main = helper.send(:filter_chain, job).to_s
          Chain.new(
            main_filters: main.empty? ? [] : main.split(','),
            sub_filters: subtitle_overlay_filters(job, :software),
            overlay_filters: []
          )
        end

        # For graphical subs we delegate to HwSubtitleOverlay when the backend
        # supports it, otherwise the SW overlay.
        def subtitle_overlay_filters(job, backend_name)
          return [] unless job.burn_subtitles?
          hw = Jellyfin::Encoding::Filters::HwSubtitleOverlay.build(job, backend_name)
          return [hw] if hw
          # SW fallback — handled by the regular filter chain via
          # Filters::SubtitleBurn.
          []
        end
      end
    end
  end
end
