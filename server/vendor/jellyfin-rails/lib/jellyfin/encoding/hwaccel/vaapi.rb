require 'jellyfin/encoding/hwaccel/base'

module Jellyfin
  module Encoding
    module Hwaccel
      # Linux VAAPI (Intel iGPU / AMD). The full upstream branch is ~170 LOC
      # with device-driver detection (iHD vs i965 vs AMD), Vulkan DRM interop,
      # and OpenCL tonemap chains. This Ruby port lands the common path —
      # software decode + VAAPI encode — and leaves driver-specific quirks for
      # subsequent iterations.
      module Vaapi
        extend Base
        module_function

        def name = :vaapi

        def available?(caps)
          caps.supports_hwaccel?('vaapi') &&
            (caps.supports_encoder?('h264_vaapi') || caps.supports_encoder?('hevc_vaapi'))
        end

        def encoder_for(target_codec, caps)
          case target_codec.to_s.downcase
          when 'h264', 'avc'  then caps.supports_encoder?('h264_vaapi') ? 'h264_vaapi' : nil
          when 'h265', 'hevc' then caps.supports_encoder?('hevc_vaapi') ? 'hevc_vaapi' : nil
          when 'av1'          then caps.supports_encoder?('av1_vaapi')  ? 'av1_vaapi'  : nil
          end
        end

        def decode_args(_job, caps)
          return [] unless caps.supports_hwaccel?('vaapi')
          device = vaapi_device
          ['-hwaccel', 'vaapi', '-hwaccel_device', device, '-hwaccel_output_format', 'vaapi']
        end

        def filter_chain(job, caps)
          chain = ['format=nv12|vaapi,hwupload']

          # HDR tonemap via OpenCL bridge — VAAPI doesn't ship a native tonemap
          # filter; the OpenCL path is what jellyfin-ffmpeg's VAAPI HDR uses.
          if job.hdr_input? && caps.supports_filter?('tonemap_opencl')
            peak = job.options.tonemapping_peak
            algo = job.options.tonemapping_algorithm
            chain << 'hwmap=derive_device=opencl'
            chain << "tonemap_opencl=tonemap=#{algo}:peak=#{peak}:format=nv12"
            chain << 'hwmap=derive_device=vaapi:reverse=1'
            chain << 'format=vaapi'
          end

          if job.output_height
            chain << "scale_vaapi=-2:'min(#{job.output_height},ih)'"
          end
          chain.join(',')
        end

        def encoder_args(job)
          args = ['-async_depth', '4']
          args.concat(rate_args_for(job))
          # Intel iHD QuickSync-compatible chips support B-frames via VAAPI;
          # older i965 does not. Best-effort: emit when driver looks new.
          args.concat(['-bf', job.options.b_frames.to_s]) if driver_supports_bframes?
          args
        end

        # Driver detection. Reads /sys/class/drm to figure out which GPU is at
        # the chosen device node so we can pick the right driver hint.
        # Returns one of :iHD (Intel modern), :i965 (Intel legacy), :amd, :unknown.
        #
        # NOTE: untested outside Linux. On Mac/Windows the env override path is
        # the only one that fires.
        def driver
          if (forced = ENV['JELLYFIN_VAAPI_DRIVER'])
            return forced.to_sym
          end
          node = File.basename(vaapi_device)
          vendor = File.read("/sys/class/drm/#{node}/device/vendor").strip rescue nil
          case vendor
          when '0x8086' then intel_driver_choice
          when '0x1002' then :amd
          else               :unknown
          end
        end

        def driver_supports_bframes?
          driver != :i965
        end

        def vaapi_device
          Jellyfin::Rails.configuration.respond_to?(:vaapi_device) &&
            Jellyfin::Rails.configuration.vaapi_device ||
            ENV.fetch('JELLYFIN_VAAPI_DEVICE', '/dev/dri/renderD128')
        end

        def intel_driver_choice
          # iHD is the modern Intel media driver (Broadwell+).
          # i965 is the legacy one for older silicon.
          # Both publish themselves under /sys/class/drm/render*/device/driver/name
          # but disambiguating that way is unreliable, so we just trust iHD by
          # default unless the user forced otherwise.
          :iHD
        end

        def rate_args_for(job)
          case job.options.rate_control
          when :cbr then ['-rc_mode', 'CBR']
          when :crf
            # VAAPI's equivalent of CRF is ICQ (Intel only). Fall back to CBR
            # on AMD where ICQ is unavailable.
            driver == :amd ? ['-rc_mode', 'CBR'] : ['-rc_mode', 'ICQ', '-global_quality', '23']
          else           ['-rc_mode', 'VBR']
          end
        end
      end
    end
  end
end
