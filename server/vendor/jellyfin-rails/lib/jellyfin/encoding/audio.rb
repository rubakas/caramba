module Jellyfin
  module Encoding
    # Full audio processing port: channel downmixing, loudness normalization,
    # dynamic range compression, resampler, layout/bitrate scaling, and the
    # itsoffset for A/V resync. Ports the audio half of EncodingHelper that
    # `Encoding::EncodingHelper#audio_args` only partially covered.
    module Audio
      # Standard ffmpeg channel layouts used at output.
      LAYOUTS = {
        1 => 'mono',
        2 => 'stereo',
        3 => '2.1',
        4 => 'quad',
        5 => '4.1',
        6 => '5.1',
        7 => '6.1',
        8 => '7.1'
      }.freeze

      # Default Dolby/ITU downmix coefficients. These mirror the matrix Jellyfin
      # uses (Lt/Rt-style with center boost). Values in dB conventions translated
      # to linear gain. Sources: ITU-R BS.775 + Dolby AC-3 downmix spec.
      #
      #   L_out = L + 0.707·C + 0.707·SL + boost
      #   R_out = R + 0.707·C + 0.707·SR + boost
      #
      # `boost` (default 2.0×) is the user-tunable `DownmixAudioBoost` option in
      # upstream's encoding settings: dialog often vanishes when 5.1 collapses
      # to stereo on small speakers, so we lift the entire mix by a fixed gain.
      def self.downmix_pan(source_channels:, target_channels:, boost: 1.0)
        return nil if source_channels.nil? || target_channels.nil?
        return nil if source_channels <= target_channels
        return nil unless target_channels == 2 # only stereo downmix supported here

        # gain * 0.707 ≈ -3dB attenuation per non-primary channel.
        g = 0.707
        case source_channels
        when 6 # 5.1 → stereo (FL FR FC LFE BL BR)
          "stereo|c0=#{boost}*FL+#{boost * g}*FC+#{boost * g}*BL|c1=#{boost}*FR+#{boost * g}*FC+#{boost * g}*BR"
        when 8 # 7.1 → stereo (FL FR FC LFE BL BR SL SR)
          "stereo|c0=#{boost}*FL+#{boost * g}*FC+#{boost * g}*BL+#{boost * g}*SL|" \
            "c1=#{boost}*FR+#{boost * g}*FC+#{boost * g}*BR+#{boost * g}*SR"
        when 3 # 2.1 → stereo: drop LFE, keep L/R
          "stereo|c0=FL|c1=FR"
        else
          # Generic N→2: average odd→L, even→R. ffmpeg can do this with pan=stereo|c0<...
          parts_l = (0...source_channels).select(&:even?).map { |i| "c#{i}" }.join('+')
          parts_r = (0...source_channels).select(&:odd?).map  { |i| "c#{i}" }.join('+')
          "stereo|c0=#{parts_l}|c1=#{parts_r}"
        end
      end

      # EBU R128 loudness normalization. Used for "night mode" and consistent
      # volume across episodes/movies. Two-pass is more accurate but stream-
      # impossible during live HLS; we use single-pass with measured I=-23 LUFS.
      def self.loudnorm_filter(target_i: -23, true_peak: -2, lra: 7)
        "loudnorm=I=#{target_i}:TP=#{true_peak}:LRA=#{lra}:linear=true"
      end

      # Dynamic Range Compression — applies when the user wants a flatter mix
      # (e.g., late-night). Threshold/ratio chosen to mirror Jellyfin's "Movie"
      # DRC default in their audio plugin.
      def self.drc_filter(threshold_db: -24, ratio: 4, attack_ms: 5, release_ms: 50)
        # `acompressor` is the ffmpeg primitive. threshold is linear (0..1), so
        # we convert from dB: linear = 10^(db/20).
        threshold_lin = format('%.5f', 10**(threshold_db.to_f / 20.0))
        "acompressor=threshold=#{threshold_lin}:ratio=#{ratio}:attack=#{attack_ms}:release=#{release_ms}"
      end

      # High-quality resampler. SoX is well-regarded; precision=28 is the
      # ffmpeg-recommended default for archival-grade rate conversion. When
      # `source_rate` matches `target_rate`, returns nil (no resample needed).
      # When the ffmpeg build lacks SoX, falls back to the default swresample.
      def self.resampler_filter(precision: 28, target_rate: nil, source_rate: nil, has_soxr: true)
        return nil if target_rate.nil?
        return nil if source_rate && source_rate.to_i == target_rate.to_i
        return "aresample=#{target_rate}" unless has_soxr
        "aresample=resampler=soxr:precision=#{precision}:osr=#{target_rate}"
      end

      # Per-channel audio bitrate scaling. Mono needs less than stereo; 5.1
      # needs ~3× stereo bitrate to sound good. Upstream uses ~64kbps/channel
      # for AAC, ~96 for AC3, ~32 for Opus.
      def self.bitrate_for(codec:, channels:, base: nil)
        per_ch = case codec.to_s.downcase
                 when 'aac', 'libfdk_aac' then 64_000
                 when 'ac3'               then 96_000
                 when 'eac3'              then 80_000
                 when 'opus', 'libopus'   then 32_000
                 when 'mp3', 'libmp3lame' then 96_000 # mp3 doesn't really scale below stereo
                 else 64_000
                 end
        scaled = per_ch * channels.to_i
        # `base` is the user-set cap; never exceed it.
        base ? [base, scaled].min : scaled
      end

      def self.channel_layout_for(channels)
        LAYOUTS[channels.to_i]
      end

      # Audio itsoffset: shift the audio track by N seconds relative to video.
      # Negative values delay audio; positive values advance it. Used to fix
      # encoder-level A/V drift seen with some PGS/embedded-sub workflows.
      def self.itsoffset_args(offset_seconds)
        return [] if offset_seconds.nil? || offset_seconds.zero?
        ['-itsoffset', format('%.3f', offset_seconds.to_f)]
      end

      # Builds the full audio filter chain. Order matters: resample first (so
      # downstream filters see the target rate), then downmix, then DRC, then
      # loudnorm last (it should see the final mix).
      def self.filter_chain(job, capabilities: nil)
        opts = job.options
        chain = []

        # SoX resampler is only invoked when the build actually has it; the
        # `-encoders` list contains "aresample" only with `--enable-libsoxr`.
        has_soxr = capabilities.respond_to?(:supports_filter?) ? capabilities.supports_filter?('aresample_libsoxr') : false
        rs = resampler_filter(target_rate: job.output_audio_sample_rate,
                              source_rate: job.audio_stream&.sample_rate,
                              has_soxr: has_soxr)
        chain << rs if rs

        src_channels = job.audio_stream&.channels
        tgt_channels = Bitrate.audio_channels_for(job)
        if (pan = downmix_pan(source_channels: src_channels, target_channels: tgt_channels, boost: opts.downmix_audio_boost || 1.0))
          chain << "pan=#{pan}"
        end

        if job.options.respond_to?(:enable_drc) && job.options.enable_drc
          chain << drc_filter
        end

        if job.options.respond_to?(:enable_loudnorm) && job.options.enable_loudnorm
          chain << loudnorm_filter
        end

        chain
      end

      # Returns the `-af` argument pair if there is a chain, else [].
      def self.filter_args(job, capabilities: nil)
        chain = filter_chain(job, capabilities: capabilities)
        chain.empty? ? [] : ['-af', chain.join(',')]
      end
    end
  end
end
