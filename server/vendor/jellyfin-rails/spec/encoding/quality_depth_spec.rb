require 'spec_helper'

RSpec.describe Jellyfin::Encoding::Quality do
  def make_job(width: 1920, height: 1080, bit_depth: 8, hdr: false, preset: 'veryfast',
               tonemap: true, opts_overrides: {})
    v = Jellyfin::Probing::MediaStream.new(
      index: 0, type: :video, codec: 'h264', width: width, height: height,
      bit_depth: bit_depth, pixel_format: bit_depth == 10 ? 'yuv420p10le' : 'yuv420p',
      video_range_type: hdr ? 'HDR10' : 'SDR'
    )
    a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac', channels: 2, sample_rate: 48_000)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: [v, a])
    opts = Jellyfin::Encoding::EncodingOptions.new
    opts.encoder_preset = preset
    opts.enable_tonemapping = tonemap
    opts_overrides.each { |k, val| opts.public_send("#{k}=", val) }
    Jellyfin::Encoding::EncodingJobInfo.new(
      media_source: src, options: opts,
      output_video_codec: 'h264',
      output_width: width, output_height: height
    )
  end

  describe '.for_x264' do
    it 'includes preset, profile, refs, and bframes' do
      args = described_class.for_x264(make_job(opts_overrides: { b_frames: 3, ref_frames: 4 }))
      expect(args).to include('-preset', 'veryfast')
      expect(args).to include('-profile:v', 'high')
      expect(args).to include('-bf', '3', '-refs', '4')
    end

    it 'forwards x264_tune when set' do
      args = described_class.for_x264(make_job(opts_overrides: { x264_tune: 'film' }))
      expect(args).to include('-tune', 'film')
    end

    it 'omits -tune when nothing has set it' do
      args = described_class.for_x264(make_job)
      expect(args).not_to include('-tune')
    end
  end

  describe '.for_x265' do
    it 'sets ctu=64 for 4K and ctu=32 for 1080p' do
      uhd = described_class.for_x265(make_job(width: 3840, height: 2160))
      hd  = described_class.for_x265(make_job(width: 1920, height: 1080))
      expect(uhd.last).to include('ctu=64')
      expect(hd.last).to include('ctu=32')
    end

    it 'rolls profile/aq/psy params into -x265-params' do
      args = described_class.for_x265(make_job(opts_overrides: { b_frames: 6, ref_frames: 3 }))
      idx = args.index('-x265-params')
      expect(args[idx + 1]).to include('bframes=6', 'ref=3', 'aq-mode=3', 'psy-rd=1.0', 'profile=main')
    end

    it 'switches to main10 profile + hdr10 params for HDR 10-bit input passthrough' do
      args = described_class.for_x265(make_job(bit_depth: 10, hdr: true, tonemap: false))
      params = args.last
      expect(params).to include('profile=main10')
      expect(params).to include('hdr10=1')
    end

    it 'omits hdr10 params when tonemapping is enabled (HDR→SDR)' do
      args = described_class.for_x265(make_job(bit_depth: 10, hdr: true, tonemap: true))
      expect(args.last).not_to include('hdr10=1')
    end

    it 'emits the hvc1 video tag for Apple compatibility' do
      args = described_class.for_x265(make_job)
      expect(args).to include('-tag:v', 'hvc1')
    end
  end

  describe '.for_svtav1' do
    it 'maps the medium symbolic preset to numeric 6' do
      args = described_class.for_svtav1(make_job(preset: 'medium'))
      expect(args).to include('-preset', '6')
    end

    it 'maps slower → 2 and veryfast → 10' do
      expect(described_class.for_svtav1(make_job(preset: 'slower'))).to include('-preset', '2')
      expect(described_class.for_svtav1(make_job(preset: 'veryfast'))).to include('-preset', '10')
    end

    it 'turns on tile-columns at 4K' do
      args = described_class.for_svtav1(make_job(width: 3840, height: 2160))
      params = args.last
      expect(params).to include('tile-columns=1')
      expect(params).to include('tile-rows=1')
    end

    it 'leaves tiles off for 1080p' do
      args = described_class.for_svtav1(make_job(width: 1920, height: 1080))
      params = args.last
      expect(params).to include('tile-columns=0')
      expect(params).to include('tile-rows=0')
    end

    it 'always emits film-grain synthesis' do
      args = described_class.for_svtav1(make_job)
      expect(args.last).to include('film-grain=8')
    end
  end

  describe '.for_vp9' do
    it 'scales tile-columns by source width' do
      expect(described_class.for_vp9(make_job(width: 3840))).to include('-tile-columns', '3')
      expect(described_class.for_vp9(make_job(width: 1920))).to include('-tile-columns', '2')
      expect(described_class.for_vp9(make_job(width: 1280))).to include('-tile-columns', '1')
      expect(described_class.for_vp9(make_job(width: 640))).to include('-tile-columns', '0')
    end

    it 'enables row-mt for parallel encoding' do
      expect(described_class.for_vp9(make_job)).to include('-row-mt', '1')
    end
  end

  describe '.for_libaom' do
    it 'sets row-mt + tiles for parallel encoding' do
      args = described_class.for_libaom(make_job)
      expect(args).to include('-row-mt', '1')
      expect(args).to include('-tiles', '2x2')
    end
  end

  describe '.for dispatcher' do
    it 'returns [] for an unknown encoder' do
      expect(described_class.for(make_job, 'mystery_codec')).to eq([])
    end
  end
end
