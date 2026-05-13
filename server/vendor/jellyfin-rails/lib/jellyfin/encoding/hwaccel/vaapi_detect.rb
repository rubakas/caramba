require 'open3'

module Jellyfin
  module Encoding
    module Hwaccel
      # Port of MediaEncoder.cs:152-164 VAAPI device-type predicates:
      #
      #   IsVaapiDeviceAmd
      #   IsVaapiDeviceInteliHD
      #   IsVaapiDeviceInteli965
      #   IsVaapiDeviceSupportVulkanDrmModifier
      #   IsVaapiDeviceSupportVulkanDrmInterop
      #
      # Upstream caches the result of a one-time vainfo probe at boot. We do
      # the same: lazy-evaluate on first access, then memoise. Driver type
      # determines which tonemap/scale filter ffmpeg can use:
      #
      #   iHD     → tonemap_vaapi + scale_vaapi (Intel modern, best path)
      #   i965    → scale_vaapi only (Intel legacy, NO HW tonemap)
      #   amdgpu  → tonemap_opencl bridge + scale_vaapi (AMD, needs OpenCL detour)
      module VaapiDetect
        VAAPI_DEVICE = ENV.fetch('JELLYFIN_VAAPI_DEVICE', '/dev/dri/renderD128').freeze

        module_function

        def amd? = info[:driver].to_s.match?(/amd|radeon|radeonsi/i)
        def intel_ihd? = info[:driver].to_s.casecmp('iHD').zero?
        def intel_i965? = info[:driver].to_s.casecmp('i965').zero?

        # Modern AMD GCN 5+ supports Vulkan DRM modifiers (required for
        # libplacebo tonemapping). Mesa 23+ is the practical floor.
        def supports_vulkan_drm_modifier?
          amd? && info[:mesa_version].to_s.match?(/\A2[3-9]|\A[3-9]\d/) ? true : false
        end

        # Vulkan ↔ VAAPI interop (DMA-BUF import). Required for the
        # zero-copy AMD pipeline.
        def supports_vulkan_drm_interop?
          supports_vulkan_drm_modifier? && info[:kernel_version].to_s.match?(/\A([5-9]|\d{2})\./) ? true : false
        end

        # Resets the memoised probe (for tests + admin tooling).
        def reset!
          @info = nil
        end

        # Returns a hash: { driver: 'iHD' | 'i965' | 'amdgpu' | nil,
        #                   mesa_version: '23.2.1' | nil,
        #                   kernel_version: '6.5.0' | nil }
        def info
          @info ||= probe
        end

        def probe
          info = { driver: nil, mesa_version: nil, kernel_version: nil }
          info[:driver] = probe_driver
          info[:mesa_version] = probe_mesa_version
          info[:kernel_version] = probe_kernel_version
          info
        end

        def probe_driver
          # `vainfo` output line: "Driver version: Intel iHD driver for ..."
          # Scan the whole "Driver version" line, not just the first token.
          out, _err, status = Open3.capture3('vainfo', '--display', 'drm', '--device', VAAPI_DEVICE)
          return nil unless status.success?
          line = out[/Driver version:[^\n]*/]
          return nil unless line
          return 'iHD' if line.include?('iHD')
          return 'i965' if line.include?('i965')
          return 'amdgpu' if line.match?(/amdgpu|radeonsi/i)
          nil
        rescue Errno::ENOENT, StandardError
          nil
        end

        def probe_mesa_version
          out, _err, status = Open3.capture3('glxinfo', '-B')
          return nil unless status.success?
          out[/Mesa\s+([0-9.]+)/, 1]
        rescue StandardError
          nil
        end

        def probe_kernel_version
          File.read('/proc/version')[/Linux version (\S+)/, 1] rescue nil
        end
      end
    end
  end
end
