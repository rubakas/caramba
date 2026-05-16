require 'spec_helper'

RSpec.describe Jellyfin::Encoding::Hwaccel do
  def caps_for(encoders:, filters: [], hwaccels: [])
    encoders = encoders.dup
    filters = filters.dup
    hwaccels = hwaccels.dup
    Struct.new(:encoders, :filters, :hwaccels).new(encoders, filters, hwaccels).tap do |c|
      def c.supports_encoder?(n); encoders.include?(n); end
      def c.supports_filter?(n);  filters.include?(n);  end
      def c.supports_hwaccel?(n); hwaccels.include?(n); end
    end
  end

  describe '.autodetect' do
    it 'picks VideoToolbox when available' do
      c = caps_for(encoders: [ 'h264_videotoolbox' ], hwaccels: [ 'videotoolbox' ])
      expect(described_class.autodetect(c)).to eq(Jellyfin::Encoding::Hwaccel::Videotoolbox)
    end

    it 'picks VAAPI when available and VideoToolbox is not' do
      c = caps_for(encoders: [ 'h264_vaapi' ], hwaccels: [ 'vaapi' ])
      expect(described_class.autodetect(c)).to eq(Jellyfin::Encoding::Hwaccel::Vaapi)
    end

    it 'returns nil when nothing is available' do
      c = caps_for(encoders: [ 'libx264' ])
      expect(described_class.autodetect(c)).to be_nil
    end
  end

  describe Jellyfin::Encoding::Hwaccel::Videotoolbox do
    let(:caps) do
      caps_for(
        encoders: %w[h264_videotoolbox hevc_videotoolbox],
        filters:  %w[tonemap_videotoolbox],
        hwaccels: %w[videotoolbox]
      )
    end

    it 'selects h264_videotoolbox for H.264 targets' do
      expect(described_class.encoder_for('h264', caps)).to eq('h264_videotoolbox')
    end

    it 'emits bare -hwaccel videotoolbox when the full HW filter chain is unavailable' do
      # Matches upstream Jellyfin (EncodingHelper.cs:6661/6982): the
      # `-hwaccel_output_format videotoolbox_vld` token is gated on
      # `useHwSurface`, which requires both `tonemap_videotoolbox` and
      # `scale_vt`. When `scale_vt` is missing (as in this fixture),
      # decoded frames must land in system memory so the SW filter
      # chain + h264_videotoolbox CPU input path works.
      #
      # Regression: a previous version emitted the format token
      # unconditionally. On 10-bit HEVC sources, GPU-resident p010
      # frames couldn't bridge into the SW filter chain → ffmpeg fell
      # back to libx264 via `-allow_sw 1` at ~1x realtime, and each
      # HLS segment took an entire segment_length of wall time to
      # produce (the user saw ~6s per .ts on Safari's Network panel).
      job = make_job
      # caps in this fixture lists tonemap_videotoolbox but NOT scale_vt.
      expect(described_class.decode_args(job, caps)).to eq(
        [ '-hwaccel', 'videotoolbox' ]
      )
    end

    it 'emits the videotoolbox_vld format only when THIS JOB will actually run on the HW filter chain' do
      # Per-job gate: even with `tonemap_videotoolbox` + `scale_vt` in
      # the build (full_chain_supported? = true), we ONLY pass
      # `-hwaccel_output_format videotoolbox_vld` when the job's filter
      # chain will actually consume HW surfaces. For an SDR source
      # there's no HW filter — leave frames in system memory so the SW
      # filter chain + `h264_videotoolbox`'s CPU input path can consume
      # them. Mirrors upstream's `useHwSurface` gate.
      full_caps = Class.new {
        def supports_hwaccel?(_) = true
        def supports_filter?(name) = %w[tonemap_videotoolbox scale_vt].include?(name)
        def supports_encoder?(name) = %w[h264_videotoolbox].include?(name)
        def supports_decoder?(_) = true
      }.new

      # SDR job: filter_chain returns nil → no format flag.
      sdr = make_job(hdr: false)
      expect(described_class.decode_args(sdr, full_caps)).to eq(
        [ '-hwaccel', 'videotoolbox' ]
      )

      # HDR job: filter_chain returns tonemap_videotoolbox → format flag.
      hdr = make_job(hdr: true)
      hdr.options.enable_tonemapping = true
      expect(described_class.decode_args(hdr, full_caps)).to eq(
        [ '-hwaccel', 'videotoolbox', '-hwaccel_output_format', 'videotoolbox_vld' ]
      )
    end

    it 'emits a tonemap_videotoolbox filter for HDR input' do
      job = make_job(hdr: true)
      chain = described_class.filter_chain(job, caps)
      expect(chain).to include('tonemap_videotoolbox=tonemap=bt2390')
    end

    # Regression: the HW tonemap leg MUST close with `hwdownload,format=nv12`
    # so frames leave the videotoolbox CVPixelBuffer surface and land in
    # system memory before the downstream encoder / auto_scale runs.
    # Without the download, ffmpeg crashes with
    #   Impossible to convert between the formats supported by the filter
    #   'Parsed_tonemap_videotoolbox_0' and the filter 'auto_scale_0'
    # the encoder never opens, no segments are written, and the init
    # segment endpoint loops on 504s — the user's "I see -1.mp4 requested
    # over and over and it fails" symptom on every HDR full-transcode
    # title (Aladdin / Ratatouille / Iron Giant 4K HDR rips). Mirrors
    # upstream Jellyfin's `EncodingHelper.GetHwTonemapFilter` which
    # always appends hwdownload + format=… after the HW tonemap step.
    it 'closes the HW tonemap chain with hwdownload+format so downstream SW consumers can read frames' do
      job = make_job(hdr: true)
      chain = described_class.filter_chain(job, caps)
      expect(chain).to include('hwdownload')
      expect(chain).to match(/hwdownload,format=(nv12|yuv420p)/)
      # `hwdownload` must come AFTER `tonemap_videotoolbox` — otherwise we
      # download SW frames that were never on the GPU surface.
      expect(chain.index('hwdownload')).to be > chain.index('tonemap_videotoolbox')
    end

    def make_job(hdr: false)
      v = Jellyfin::Probing::MediaStream.new(
        index: 0, type: :video, codec: hdr ? 'hevc' : 'h264',
        width: 3840, height: 2160, frame_rate: 24.0,
        video_range: hdr ? 'HDR' : 'SDR',
        video_range_type: hdr ? 'HDR10' : 'SDR'
      )
      source = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: [ v ])
      Jellyfin::Encoding::EncodingJobInfo.new(media_source: source)
    end
  end

  describe Jellyfin::Encoding::Hwaccel::Qsv do
    # Caps with a QSV decoder available for h264 — triggers the HW-decode
    # branch (vpp_qsv on QSV surfaces).
    let(:hw_caps) do
      Class.new do
        def supports_encoder?(n); %w[h264_qsv hevc_qsv].include?(n); end
        def supports_filter?(n);  %w[vpp_qsv scale_qsv hwupload].include?(n); end
        def supports_hwaccel?(n); n == 'qsv'; end
        def supports_decoder?(n); %w[h264_qsv hevc_qsv vp9_qsv av1_qsv mpeg2_qsv].include?(n); end
      end.new
    end

    # Caps WITHOUT a QSV decoder for the source codec — exercises the
    # SW-decode → h264_qsv encode branch.
    let(:sw_caps) do
      Class.new do
        def supports_encoder?(n); %w[h264_qsv].include?(n); end
        def supports_filter?(n);  true; end
        def supports_hwaccel?(n); n == 'qsv'; end
        def supports_decoder?(_); false; end
      end.new
    end

    # Regression: device init must precede everything (so `-filter_hw_device qs`
    # binds vpp_qsv / h264_qsv to the QSV-on-VAAPI device). Mirrors
    # GetQsvDeviceArgs on Linux (EncodingHelper.cs:938-960) chaining
    # vaapi=va:/dev/dri/renderD128,driver=iHD → qsv=qs@va → -filter_hw_device qs.
    it 'emits VAAPI→QSV device chain and pins the filter device' do
      job = make_job
      args = described_class.decode_args(job, hw_caps)
      expect(args).to include('-init_hw_device')
      expect(args).to include(a_string_starting_with('vaapi=va:'))
      expect(args).to include('qsv=qs@va')
      expect(args).to include('-filter_hw_device')
      expect(args).to include('qs')
    end

    # Regression: when ffmpeg has a QSV decoder for the source codec
    # (h264_qsv here), decode runs on the iGPU AND outputs QSV surfaces
    # so the filter graph can run on-GPU (vpp_qsv + h264_qsv). Upstream
    # EncodingHelper.cs:4760-4807 takes the same branch.
    it 'requests -hwaccel_output_format qsv when a QSV decoder is available' do
      job = make_job
      args = described_class.decode_args(job, hw_caps)
      expect(args.each_cons(2).to_a).to include([ '-hwaccel', 'qsv' ])
      expect(args.each_cons(2).to_a).to include([ '-hwaccel_output_format', 'qsv' ])
    end

    # Regression: codecs without a QSV decoder fall back to SW decode +
    # h264_qsv encode. Setting `-hwaccel qsv -hwaccel_output_format qsv`
    # in that case blew up format negotiation (the original Iron Giant
    # bug — ffmpeg auto_scale couldn't bridge QSV surfaces to the SW
    # filter chain). On SW decode we only emit the device-init args; the
    # SW decoder runs without hwaccel and the resulting CPU NV12 frames
    # are handed straight to h264_qsv, which uploads them internally
    # using the QSV device we already wired up.
    it 'omits -hwaccel and -hwaccel_output_format when no QSV decoder is available' do
      job = make_job
      args = described_class.decode_args(job, sw_caps)
      expect(args).not_to include('-hwaccel')
      expect(args).not_to include('-hwaccel_output_format')
      expect(args).to include('-init_hw_device') # device chain still needed for h264_qsv
      expect(args).to include('-filter_hw_device')
    end

    # Regression: HW-decode branch uses vpp_qsv (the single-pass GPU
    # filter that does scale + format + tonemap) — no hwupload needed
    # since frames are already on the iGPU. Mirrors hwScalePrefix="vpp"
    # in upstream EncodingHelper.cs:4785.
    #
    # Width/height MUST be concrete integers; vpp_qsv's parser silently
    # stalls the pipeline if you hand it ffmpeg expressions like
    # `-2` or `min(N,ih)`. Mirrors `GetFixedOutputSize` (cs:3255).
    it 'uses vpp_qsv with concrete dims for the HW-decode filter chain' do
      job = make_job(src_width: 3840, src_height: 2160, output_height: 1080)
      chain = described_class.filter_chain(job, hw_caps)
      expect(chain).to eq('vpp_qsv=w=1920:h=1080:format=nv12')
    end

    it 'uses vpp_qsv=format=nv12 when no resize is needed (HW decode)' do
      job = make_job
      chain = described_class.filter_chain(job, hw_caps)
      expect(chain).to eq('vpp_qsv=format=nv12')
    end

    # Regression: SW-decode branch hands CPU NV12 to h264_qsv, which
    # uploads to the iGPU internally. No explicit `hwupload` filter —
    # adding one breaks ffmpeg's format negotiation when input is
    # CPU-side yuv420p ("Impossible to convert between the formats
    # supported by the filter 'Parsed_hwupload_1' and the filter
    # 'auto_scale_0'"). Mirrors EncodingHelper.cs:4750 which ends the
    # SW branch with `format=nv12` and lets the HW encoder do the upload.
    it 'uses SW scale + format=nv12 for the SW-decode filter chain (no hwupload)' do
      job = make_job(src_width: 3840, src_height: 2160, output_height: 1080)
      chain = described_class.filter_chain(job, sw_caps)
      expect(chain).to eq('scale=1920:1080:flags=lanczos,format=nv12')
      expect(chain).not_to include('hwupload')
      expect(chain).not_to include('vpp_qsv')
    end

    it 'still emits format=nv12 when no resize is needed (SW decode)' do
      job = make_job
      chain = described_class.filter_chain(job, sw_caps)
      expect(chain).to eq('format=nv12')
    end

    # Regression: 4K HEVC HDR rips (Aladdin etc.) used to silently stall
    # h264_qsv — vpp_qsv converted P010 → NV12 but left HDR signaling on
    # the frames, and the H.264 encoder (8-bit, no HDR support) hung
    # mid-pipeline. Init-segment requests looped on 504s with no error
    # message. Upstream EncodingHelper.cs:4537 appends `:tonemap=1` to
    # vpp_qsv for HDR sources — Gen11+ iHD performs HDR-PQ → SDR-Rec.709
    # conversion in the same VPL pass. Without it, the encoder gets
    # garbage.
    it 'appends :tonemap=1 to vpp_qsv when input is HDR (HW decode)' do
      job = make_job(codec: 'hevc', hdr: true, src_width: 3840, src_height: 2160, output_height: 1080)
      chain = described_class.filter_chain(job, hw_caps)
      expect(chain).to eq('vpp_qsv=w=1920:h=1080:format=nv12:tonemap=1')
    end

    it 'omits :tonemap=1 on SDR sources (HW decode)' do
      job = make_job(codec: 'hevc', hdr: false, output_height: 1080)
      chain = described_class.filter_chain(job, hw_caps)
      expect(chain).not_to include('tonemap=1')
    end

    # SW-decode HDR: same end-state (nv12 SDR) but via the zscale/tonemap
    # software leg since vpp_qsv isn't reachable from CPU frames.
    it 'inserts a zscale+tonemap leg before format=nv12 on SW-decode HDR' do
      job = make_job(codec: 'hevc', hdr: true)
      chain = described_class.filter_chain(job, sw_caps)
      expect(chain).to include('zscale=t=linear')
      expect(chain).to match(/tonemap=hable/)
      expect(chain).to end_with('format=nv12')
    end

    def make_job(output_height: nil, codec: 'h264', hdr: false, src_width: 1920, src_height: 1080)
      v = Jellyfin::Probing::MediaStream.new(
        index: 0, type: :video, codec: codec,
        width: src_width, height: src_height, frame_rate: 24.0,
        video_range: hdr ? 'HDR' : 'SDR',
        video_range_type: hdr ? 'HDR10' : 'SDR'
      )
      source = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: [ v ])
      Jellyfin::Encoding::EncodingJobInfo.new(
        media_source: source,
        output_video_codec: 'h264'
      ).tap do |job|
        job.define_singleton_method(:output_height) { output_height }
      end
    end

    # Regression: ICQ mode (`-global_quality N`) on h264_qsv produces
    # visibly worse output than the source on complex scenes — the
    # quality target lets the encoder drop bitrate aggressively. The
    # pre-jellyfin-rails transcoder targeted SOURCE bitrate (so a
    # 12 Mbps BluRay rip stays at ~12 Mbps after transcode = looks
    # original), and that's also what upstream Jellyfin does for QSV
    # (EncodingHelper.cs:1644). User-visible symptom: "old Caramba on
    # a 10-year-old Mac looks better than new Caramba on the NAS".
    it 'emits bitrate-targeted VBR args (-b:v / -maxrate / -bufsize)' do
      job = make_job
      job.output_video_bitrate = 10_000_000
      args = described_class.encoder_args(job)
      pairs = args.each_cons(2).to_a
      expect(pairs).to include([ '-b:v', '10000000' ])
      expect(pairs).to include([ '-maxrate', '10000001' ])
      expect(pairs).to include([ '-rc_init_occupancy', /\A\d+\z/ ].map(&:to_s).then { |p| pairs.find { |x| x[0] == p[0] } })
      expect(args).to include('-bufsize')
    end

    it 'omits -global_quality (mutually exclusive with -b:v VBR)' do
      job = make_job
      args = described_class.encoder_args(job)
      expect(args).not_to include('-global_quality')
    end

    it 'scales target bitrate down for HEVC output (60% of H.264)' do
      job = make_job
      job.output_video_bitrate = 10_000_000
      job.output_video_codec = 'hevc'
      args = described_class.encoder_args(job)
      # Bitrate.video_bitrate_for applies the 0.6 codec scale for hevc.
      expect(args.each_cons(2).to_a).to include([ '-b:v', '6000000' ])
    end

    # Regression: `-preset medium` produced 30-60s first-segment latency
    # on 4K sources (encoder pipeline takes ~6s of source frames to flush
    # the init segment at ~0.1× realtime; medium is way too slow on a
    # 15W iGPU). Upstream defaults QSV to `veryfast` (EncodingHelper.cs:
    # 1761) — the HW encoder's quality is fixed by `-global_quality`, not
    # by software preset, so faster preset = same quality + much lower
    # latency. Symptom: "almost a minute to start playback, every seek
    # takes the same time, this is not acceptable".
    it 'uses -preset veryfast (not medium) for fast first-segment + seek' do
      job = make_job
      args = described_class.encoder_args(job)
      expect(args.each_cons(2).to_a).to include([ '-preset', 'veryfast' ])
    end

    # Regression (negative): `-low_power 1` switches QSV to Intel's
    # VDEnc fixed-function encoder. It's FASTER but visibly LOWER quality
    # at the same -global_quality target, AND it runs on a separate
    # engine that standard GPU monitors don't surface (so the iGPU looks
    # idle when it isn't). Upstream defaults it OFF behind
    # EnableIntelLowPowerH264HwEncoder. We do the same — until the option
    # is wired up explicitly, low_power stays absent.
    it 'does NOT enable -low_power by default (preserves quality)' do
      job = make_job
      args = described_class.encoder_args(job)
      expect(args).not_to include('-low_power')
    end

    # Regression: `-mbbrc 1` (MacroBlock-level bitrate control) is the
    # main quality knob beyond `-global_quality` for QSV; distributes
    # bits to busy regions, gives a visibly cleaner picture at the same
    # average bitrate. Without it the encoder is uniform-quality and
    # busy scenes get blocky. Upstream cs:1621.
    it 'enables -mbbrc 1 for MacroBlock-level rate control (quality boost)' do
      job = make_job
      args = described_class.encoder_args(job)
      expect(args.each_cons(2).to_a).to include([ '-mbbrc', '1' ])
    end
  end

  describe Jellyfin::Encoding::EncodingHelper, 'graphical-subtitle burn-in HW fallback' do
    # Regression: when a graphical (PGS/DVB/DVD) subtitle is being burned
    # into the video, the HW backend MUST be refused. `HwSubtitleOverlay`
    # emits a single overlay filter (overlay_qsv / overlay_vaapi /
    # overlay_cuda) which is a 2-input filter; the sub-stream
    # pre-processing chain that feeds its second input isn't built yet.
    # If we still pick a HW backend, ffmpeg auto-inserts a phantom
    # `hwupload` for the missing input and the chain dies with
    # "Impossible to convert between the formats supported by the filter
    # 'Parsed_hwupload_1' and the filter 'auto_scale_0'". User-visible
    # symptom: every full_transcode title with graphical subs loops on
    # init-segment 504s. Refusing HW here keeps the SW PgsOverlay path
    # alive — slower but functionally correct. Drop this gate once the
    # dual-graph upload chain (upstream EncodingHelper.cs:4893-4929) is
    # ported.
    it 'refuses the HW backend when graphical subtitle burn-in is required' do
      caps = Class.new do
        def supports_encoder?(name); %w[libx264 h264_qsv h264_vaapi aac].include?(name); end
        def supports_filter?(name);  %w[scale scale_qsv scale_vaapi hwupload overlay_qsv overlay_vaapi].include?(name); end
        def supports_hwaccel?(name); %w[qsv vaapi].include?(name); end
        def supports_decoder?(_);    true; end
      end.new
      v = Jellyfin::Probing::MediaStream.new(
        index: 0, type: :video, codec: 'h264',
        width: 1920, height: 1080, frame_rate: 24.0,
        video_range: 'SDR', video_range_type: 'SDR'
      )
      s = Jellyfin::Probing::MediaStream.new(
        index: 1, type: :subtitle, codec: 'pgssub'
      )
      source = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: [ v, s ])
      options = Jellyfin::Encoding::EncodingOptions.new
      options.enable_hardware_encoding = true
      options.hardware_acceleration_type = :qsv
      job = Jellyfin::Encoding::EncodingJobInfo.new(
        media_source: source,
        options: options,
        output_video_codec: 'h264',
        subtitle_stream: s,
        subtitle_method: :encode
      )
      helper = described_class.new(caps)
      expect(helper.send(:resolve_hwaccel, job)).to be_nil
    end

    it 'keeps the HW backend when no subtitle burn-in is needed' do
      caps = Class.new do
        def supports_encoder?(name); %w[libx264 h264_qsv aac].include?(name); end
        def supports_filter?(name);  %w[scale scale_qsv hwupload].include?(name); end
        def supports_hwaccel?(name); name == 'qsv'; end
        def supports_decoder?(_);    true; end
      end.new
      v = Jellyfin::Probing::MediaStream.new(
        index: 0, type: :video, codec: 'h264',
        width: 1920, height: 1080, frame_rate: 24.0,
        video_range: 'SDR', video_range_type: 'SDR'
      )
      source = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: [ v ])
      options = Jellyfin::Encoding::EncodingOptions.new
      options.enable_hardware_encoding = true
      options.hardware_acceleration_type = :qsv
      job = Jellyfin::Encoding::EncodingJobInfo.new(
        media_source: source, options: options, output_video_codec: 'h264'
      )
      helper = described_class.new(caps)
      expect(helper.send(:resolve_hwaccel, job)).to eq(Jellyfin::Encoding::Hwaccel::Qsv)
    end
  end

  describe Jellyfin::Encoding::EncodingHelper, 'with HW accel' do
    it 'uses h264_videotoolbox when HW accel is enabled and available' do
      caps = Class.new do
        def supports_encoder?(name); %w[libx264 h264_videotoolbox aac].include?(name); end
        def supports_filter?(name);  %w[scale tonemap_videotoolbox].include?(name); end
        def supports_hwaccel?(name); name == 'videotoolbox'; end
        def supports_decoder?(_);    true; end
      end.new
      options = Jellyfin::Encoding::EncodingOptions.new
      options.enable_hardware_encoding = true
      options.hardware_acceleration_type = :videotoolbox
      source = Jellyfin::Probing::MediaSourceInfo.new(
        path: '/x.mkv',
        streams: [
          Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264', width: 1920, height: 1080, frame_rate: 24.0, video_range: 'SDR', video_range_type: 'SDR'),
          Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac', channels: 2, sample_rate: 48_000)
        ]
      )
      job = Jellyfin::Encoding::EncodingJobInfo.new(
        media_source: source, options: options, output_video_codec: 'h264'
      )
      args = described_class.command_line_arguments(
        job, playlist_path: '/tmp/o.m3u8', segment_template: '/tmp/%d.ts', capabilities: caps
      )
      expect(args).to include('-c:v', 'h264_videotoolbox')
      expect(args).to include('-hwaccel', 'videotoolbox')
    end
  end
end
