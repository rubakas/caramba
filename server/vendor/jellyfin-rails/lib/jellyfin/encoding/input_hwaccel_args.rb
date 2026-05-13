module Jellyfin
  module Encoding
    # Port of EncodingHelper.GetInputVideoHwaccelArgs (cs:1002). Builds the
    # unified `-hwaccel <vendor> -hwaccel_device <N> -hwaccel_output_format
    # <fmt>` arg list for the input stream.
    #
    # Upstream's ~200-line method handles every vendor's quirks: VAAPI device
    # paths, multi-GPU NVENC selection, AMD Vulkan interop, Intel iHD vs i965
    # driver overrides, Apple VideoToolbox feature flags. Our port dispatches
    # to each backend's `decode_args` (which already handles vendor specifics),
    # and adds the cross-vendor argument shaping.
    module InputHwaccelArgs
      module_function

      def call(job:, capabilities:)
        # No-op for stream copy (upstream short-circuits at cs:1010).
        return [] if job.stream_copy_video?

        accel_type = job.options.hardware_acceleration_type
        return [] if accel_type.nil? || accel_type == :none

        backend =
          case accel_type
          when :amf          then Jellyfin::Encoding::Hwaccel::Amf
          when :qsv          then Jellyfin::Encoding::Hwaccel::Qsv
          when :nvenc        then Jellyfin::Encoding::Hwaccel::Nvenc
          when :vaapi        then Jellyfin::Encoding::Hwaccel::Vaapi
          when :videotoolbox then Jellyfin::Encoding::Hwaccel::Videotoolbox
          when :rkmpp        then Jellyfin::Encoding::Hwaccel::Rkmpp
          end

        return [] if backend.nil? || !backend.available?(capabilities)
        backend.decode_args(job, capabilities)
      end
    end
  end
end
