module Jellyfin
  module Encoding
    # Per-encoder fine-grained quality controls. Ports GetVideoQualityParam +
    # GetX265ParamsArg + GetSvtAv1ParamsArg from EncodingHelper.cs.
    #
    # Each public method returns the FFmpeg args appended after `-c:v <encoder>`
    # but BEFORE rate-control. The split lets callers swap in/out rate-control
    # strategies (CRF/CBR/VBR) without re-deriving quality params.
    module Quality
      # x264 content-aware tune. The values mirror x264's --tune options.
      # Auto-detection heuristics (from EncodingHelper):
      #   - animation: source codec is animated content marker
      #   - grain: dynamic_range=film + colorspace=bt709 + bitdepth=10
      #   - stillimage: video stream marked as still-frame
      #   - zerolatency: live profile (we never use this for VOD)
      X264_TUNES = %w[film animation grain stillimage psnr ssim fastdecode zerolatency].freeze

      module_function

      def for(job, encoder)
        case encoder.to_s.downcase
        when 'libx264'      then for_x264(job)
        when 'libx265'      then for_x265(job)
        when 'libsvtav1'    then for_svtav1(job)
        when 'libaom-av1'   then for_libaom(job)
        when 'libvpx-vp9'   then for_vp9(job)
        when 'libvpx'       then for_vp8(job)
        else []
        end
      end

      def for_x264(job)
        opts = job.options
        args = ['-preset', opts.encoder_preset]
        tune = opts.respond_to?(:x264_tune) ? opts.x264_tune : x264_tune_default(job)
        args.concat(['-tune', tune]) if tune
        args.concat(['-profile:v', ProfileMapping.for_h264(job)])
        args.concat(['-bf', opts.b_frames.to_s, '-refs', opts.ref_frames.to_s])
        args
      end

      def for_x265(job)
        opts = job.options
        profile = ProfileMapping.for_h265(job)
        # x265 understands a rich `--x265-params key=value:key2=value2` string.
        # Important parameters mirrored from upstream:
        #   ctu (coding tree unit): 64 for >1080p, 32 otherwise — wider CTUs
        #     waste cycles on lower resolutions.
        #   aq-mode=3 (variance + bias) gives the visually best result for
        #     mixed live-action content.
        #   psy-rd controls psycho-visual rate-distortion. Higher = subjectively
        #     sharper but objectively-noisier.
        ctu = wide_ctu?(job) ? 64 : 32
        params = [
          "bframes=#{opts.b_frames}",
          "ref=#{opts.ref_frames}",
          "ctu=#{ctu}",
          'aq-mode=3',
          'psy-rd=1.0',
          'psy-rdoq=1.0',
          "profile=#{profile}"
        ]
        params << 'hdr10=1'      if job.hdr_input? && !job.options.enable_tonemapping
        params << 'hdr10-opt=1'  if job.hdr_input? && !job.options.enable_tonemapping

        # Dolby Vision passthrough — append DV-aware params when present, the
        # output is HEVC, and tone-mapping isn't going to flatten the layer.
        if !job.options.enable_tonemapping && DolbyVision.present?(job.video_stream)
          rpu_file = job.options.respond_to?(:dovi_rpu_path) ? job.options.dovi_rpu_path : nil
          dv = DolbyVision.x265_params(job.video_stream, rpu_file: rpu_file)
          params << dv if dv
        end

        # HDR10+ dynamic metadata SEI passthrough — applies on top of the
        # static HDR10 metadata. Different from DV (RPU layer).
        if !job.options.enable_tonemapping && Hdr10Plus.present?(job.video_stream)
          h10p = Hdr10Plus.x265_params(job.video_stream)
          params << h10p if h10p
        end

        ['-preset', opts.encoder_preset, '-profile:v', profile, '-tag:v', 'hvc1',
         '-x265-params', params.join(':')]
      end

      def for_svtav1(job)
        opts = job.options
        # SVT-AV1 preset: 0..13 (low = high quality, slow). 6 is the upstream
        # default for VOD; 8 is the live/fast default. We honor encoder_preset
        # if it's already numeric (the option is shared with x264/x265).
        preset = svtav1_preset(opts.encoder_preset)
        tile_cols = job.output_width.to_i > 1920 ? 1 : 0
        tile_rows = job.output_height.to_i > 1080 ? 1 : 0
        params = [
          "lookahead=#{opts.lookahead}",
          'film-grain=8',
          "tile-columns=#{tile_cols}",
          "tile-rows=#{tile_rows}",
          'enable-overlays=1',
          'scd=1'
        ]
        ['-preset', preset.to_s, '-svtav1-params', params.join(':')]
      end

      def for_libaom(job)
        opts = job.options
        # libaom-av1 is slower; we use higher cpu-used and row-mt for speed.
        ['-cpu-used', '4',
         '-row-mt', '1',
         '-tiles', '2x2',
         '-lag-in-frames', opts.lookahead.to_s]
      end

      def for_vp9(job)
        opts = job.options
        # VP9 quality knobs based on Google's recommended settings for 1080p+.
        # tile-columns and row-mt parallelize the encoder across cores.
        ['-deadline', 'good',
         '-cpu-used', '2',
         '-row-mt', '1',
         '-tile-columns', tile_columns_for(job).to_s,
         '-frame-parallel', '1',
         '-auto-alt-ref', '1',
         '-lag-in-frames', opts.lookahead.to_s]
      end

      def for_vp8(_job)
        # VP8 has very few useful knobs by 2026. Keep it minimal.
        ['-deadline', 'good', '-cpu-used', '2']
      end

      def x264_tune_default(job)
        # Heuristic — animated content tends to have "animation" or "anime" in
        # the title/codec tags; we don't have probe support for that, so the
        # safe-by-default is no tune.
        return 'animation' if job.video_stream&.codec_long_name.to_s.downcase.include?('animation')
        nil
      end

      def wide_ctu?(job)
        height = job.output_height || job.video_stream&.height || 0
        height > 1080
      end

      def svtav1_preset(symbolic_or_numeric)
        # Map x264-style preset names to SVT-AV1's numeric scale.
        case symbolic_or_numeric.to_s
        when /^\d+$/                 then symbolic_or_numeric.to_i
        when 'ultrafast', 'superfast' then 12
        when 'veryfast', 'faster'    then 10
        when 'fast'                  then 8
        when 'medium'                then 6
        when 'slow'                  then 4
        when 'slower'                then 2
        when 'veryslow', 'placebo'   then 1
        else 6
        end
      end

      def tile_columns_for(job)
        w = job.output_width || job.video_stream&.width || 1920
        return 3 if w >= 3840
        return 2 if w >= 1920
        return 1 if w >= 1280
        0
      end
    end
  end
end
