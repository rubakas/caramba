module Jellyfin
  module Encoding
    module Filters
      # Hardware-accelerated subtitle burn-in. Without this, a HW decode + HW
      # encode pipeline has to `hwdownload` to system memory just to overlay
      # subs and `hwupload` back — that round-trip eats most of the GPU's
      # benefit. With HW overlay, the entire path stays on the GPU.
      #
      # ffmpeg provides accel-specific overlay filters:
      #   overlay_cuda     (NVIDIA)
      #   overlay_qsv      (Intel Quick Sync)
      #   overlay_vaapi    (Linux VAAPI / AMD / older Intel)
      #
      # VideoToolbox (Apple) doesn't expose a HW overlay filter, so we fall
      # back to SW.
      module HwSubtitleOverlay
        module_function

        # Returns the filter-graph fragment, or nil when HW overlay isn't
        # applicable. `accel_name` is the Hwaccel backend symbol.
        def build(job, accel_name)
          return nil unless job.burn_subtitles?
          codec = job.subtitle_stream&.codec.to_s.downcase
          # Graphical subs use the regular overlay primitive; the HW variants
          # only handle texture overlays.
          return nil unless graphical?(codec)

          case accel_name
          when :nvenc, :cuda                  then "overlay_cuda=x=0:y=0"
          when :qsv                           then "overlay_qsv=x=0:y=0"
          when :vaapi                         then "overlay_vaapi=x=0:y=0"
          else nil # videotoolbox / no-accel — SW path handles it
          end
        end

        def graphical?(codec)
          %w[hdmv_pgs_subtitle pgssub dvd_subtitle dvbsub].include?(codec)
        end
      end
    end
  end
end
