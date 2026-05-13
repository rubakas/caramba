module Jellyfin
  module Encoding
    # Dolby Vision passthrough + transcode helpers. Mirrors the DV-aware paths
    # in EncodingHelper.cs (Get*EncodingProfile + GetVideoEncodingParam).
    #
    # Dolby Vision has multiple "profiles" with different bitstream layouts:
    #
    #   Profile 5  — single layer, IPTPQc2 (BL only, no fallback)
    #   Profile 7  — dual layer, HEVC BL + EL + RPU (typical UHD Blu-ray)
    #   Profile 8  — single layer with HDR10 fallback (Apple TV / Netflix)
    #   Profile 81 — DV + HDR10 cross-compatible (Profile 8.1)
    #   Profile 84 — DV + HLG cross-compatible (Profile 8.4)
    #
    # Pass-through paths:
    #
    #   1. STREAM COPY — input bytes go through unchanged. We just need ffmpeg
    #      to forward the DV side data. The `-strict unofficial` flag is
    #      required because DV NAL unit types aren't in the HEVC spec.
    #
    #   2. TRANSCODE — to retain DV we have to re-emit the RPU layer. Modern
    #      x265 builds (>=3.5 with --enable-dolby-vision) accept
    #      `--dolby-vision-profile=N` and a pre-extracted `--dolby-vision-rpu=
    #      rpu.bin`. We can extract the RPU once and cache it.
    module DolbyVision
      module_function

      # True when the source carries DV side data (RPU layer present).
      def present?(stream)
        return false unless stream
        return true if stream.video_range_type.to_s.casecmp('DOVI').zero?
        !stream.dovi_profile.nil?
      end

      # Cross-compatible profiles can fall back to HDR10 / HLG without DV-aware
      # clients. Profile 5 cannot — it's DV-only.
      def cross_compatible?(stream)
        return false unless present?(stream)
        [7, 8, 81, 84].include?(stream.dovi_profile.to_i)
      end

      # Args to pass DV through during stream-copy or when ffmpeg muxes the
      # bitstream onto a fresh container. Forwarded by the global args list.
      def passthrough_input_args
        ['-strict', 'unofficial']
      end

      # x265-params fragments to retain DV during transcode. Returns nil when
      # the source isn't DV. `rpu_file` must be pre-extracted (see extract_rpu!).
      def x265_params(stream, rpu_file: nil)
        return nil unless present?(stream)
        params = ["dolby-vision-profile=#{stream.dovi_profile}"]
        params << "dolby-vision-rpu=#{rpu_file}" if rpu_file
        # Cross-compatible profiles need this so x265 emits the HDR10 fallback.
        params << 'vbv-bufsize=160000' if cross_compatible?(stream)
        params << 'vbv-maxrate=160000' if cross_compatible?(stream)
        params.join(':')
      end

      # Top-level output args that affect the muxer rather than the encoder.
      def output_args(stream)
        return [] unless present?(stream)
        # `-dolbyvision true` on the muxer tells ffmpeg to keep the DV
        # configuration record in the output container.
        ['-dolbyvision', 'true']
      end

      # Extracts the RPU layer to a sidecar file using `dovi_tool`. The result
      # is cached by (path, mtime). Returns the RPU path on success, nil if
      # dovi_tool is unavailable.
      def extract_rpu!(source_path, cache_dir:)
        require 'open3'
        require 'digest'
        digest = Digest::SHA1.hexdigest(File.expand_path(source_path))
        out_path = File.join(cache_dir, "#{digest}.rpu.bin")
        return out_path if File.exist?(out_path) && rpu_fresh?(out_path, source_path)

        require 'fileutils'
        FileUtils.mkdir_p(cache_dir)
        # `dovi_tool extract-rpu` reads an HEVC elementary stream from stdin.
        # We pipe ffmpeg's bitstream through it.
        ff = Jellyfin::Rails.configuration.ffmpeg_path
        cmd = "#{ff} -hide_banner -loglevel error -i #{escape_path(source_path)} " \
              '-c:v copy -bsf:v hevc_mp4toannexb -f hevc - | ' \
              "dovi_tool extract-rpu - -o #{escape_path(out_path)}"
        _out, _err, status = Open3.capture3('sh', '-c', cmd)
        return nil unless status.success? && File.exist?(out_path) && File.size(out_path).positive?
        out_path
      rescue StandardError
        nil
      end

      def rpu_fresh?(rpu_path, source_path)
        File.mtime(rpu_path) >= File.mtime(source_path)
      rescue Errno::ENOENT
        false
      end

      def escape_path(p)
        # Single-quote for shell, escape any embedded single quotes.
        "'#{p.gsub("'", "'\\''")}'"
      end
    end
  end
end
