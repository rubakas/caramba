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
    it 'uses vpp_qsv for the HW-decode filter chain' do
      job = make_job(output_height: 720)
      chain = described_class.filter_chain(job, hw_caps)
      expect(chain).to eq("vpp_qsv=w=-2:h='min(720,ih)':format=nv12")
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
      job = make_job(output_height: 1080)
      chain = described_class.filter_chain(job, sw_caps)
      expect(chain).to eq("scale=-2:'min(1080,ih)':flags=lanczos,format=nv12")
      expect(chain).not_to include('hwupload')
      expect(chain).not_to include('vpp_qsv')
    end

    it 'still emits format=nv12 when no resize is needed (SW decode)' do
      job = make_job
      chain = described_class.filter_chain(job, sw_caps)
      expect(chain).to eq('format=nv12')
    end

    def make_job(output_height: nil)
      v = Jellyfin::Probing::MediaStream.new(
        index: 0, type: :video, codec: 'h264',
        width: 1920, height: 1080, frame_rate: 24.0,
        video_range: 'SDR', video_range_type: 'SDR'
      )
      source = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: [ v ])
      Jellyfin::Encoding::EncodingJobInfo.new(
        media_source: source,
        output_video_codec: 'h264'
      ).tap do |job|
        job.define_singleton_method(:output_height) { output_height }
      end
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
