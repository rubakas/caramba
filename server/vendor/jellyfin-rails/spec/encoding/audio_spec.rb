require 'spec_helper'

RSpec.describe Jellyfin::Encoding::Audio do
  def make_job(channels:, codec_in: 'eac3', codec_out: 'aac', sample_rate: 48_000,
               output_channels: nil, opts_overrides: {})
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264', width: 1920, height: 1080)
    a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: codec_in,
      channels: channels, sample_rate: sample_rate, bit_rate: 384_000)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x', streams: [v, a])
    opts = Jellyfin::Encoding::EncodingOptions.new
    opts_overrides.each { |k, val| opts.public_send("#{k}=", val) }
    Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, options: opts,
      output_audio_codec: codec_out, output_audio_channels: output_channels,
      output_audio_sample_rate: 48_000)
  end

  describe '.downmix_pan' do
    it 'emits boosted 5.1→stereo matrix with center+rear blending' do
      pan = described_class.downmix_pan(source_channels: 6, target_channels: 2, boost: 2.0)
      expect(pan).to include('c0=2.0*FL')
      expect(pan).to include('FC')
      expect(pan).to include('BL')
    end

    it 'emits 7.1→stereo matrix including side channels' do
      pan = described_class.downmix_pan(source_channels: 8, target_channels: 2, boost: 1.0)
      expect(pan).to include('SL')
      expect(pan).to include('SR')
    end

    it 'returns nil for upmix attempts' do
      expect(described_class.downmix_pan(source_channels: 2, target_channels: 6)).to be_nil
    end

    it 'returns nil for non-stereo targets (not supported here)' do
      expect(described_class.downmix_pan(source_channels: 8, target_channels: 6)).to be_nil
    end
  end

  describe '.loudnorm_filter' do
    it 'emits EBU R128 spec by default' do
      f = described_class.loudnorm_filter
      expect(f).to include('I=-23')
      expect(f).to include('TP=-2')
      expect(f).to include('LRA=7')
      expect(f).to include('linear=true')
    end
  end

  describe '.drc_filter' do
    it 'converts dB threshold to linear before passing to acompressor' do
      f = described_class.drc_filter(threshold_db: -24)
      expect(f).to start_with('acompressor=')
      # 10^(-24/20) ≈ 0.06310
      expect(f).to match(/threshold=0\.0631/)
    end
  end

  describe '.resampler_filter' do
    it 'returns SoX resampler when ffmpeg has libsoxr' do
      f = described_class.resampler_filter(target_rate: 48_000, source_rate: 44_100, has_soxr: true)
      expect(f).to eq('aresample=resampler=soxr:precision=28:osr=48000')
    end

    it 'falls back to swresample when SoX is unavailable' do
      f = described_class.resampler_filter(target_rate: 48_000, source_rate: 44_100, has_soxr: false)
      expect(f).to eq('aresample=48000')
    end

    it 'returns nil when source and target rates match' do
      expect(described_class.resampler_filter(target_rate: 48_000, source_rate: 48_000, has_soxr: true)).to be_nil
    end

    it 'returns nil when target rate is unknown' do
      expect(described_class.resampler_filter(target_rate: nil)).to be_nil
    end
  end

  describe '.bitrate_for' do
    it 'scales AAC ~64kbps per channel' do
      expect(described_class.bitrate_for(codec: 'aac', channels: 2)).to eq(128_000)
      expect(described_class.bitrate_for(codec: 'aac', channels: 6)).to eq(384_000)
    end

    it 'uses Opus low-bitrate scaling' do
      expect(described_class.bitrate_for(codec: 'opus', channels: 2)).to eq(64_000)
    end

    it 'respects the user-set cap when smaller' do
      expect(described_class.bitrate_for(codec: 'aac', channels: 8, base: 256_000)).to eq(256_000)
    end
  end

  describe '.channel_layout_for' do
    it 'maps standard counts to ffmpeg names' do
      expect(described_class.channel_layout_for(2)).to eq('stereo')
      expect(described_class.channel_layout_for(6)).to eq('5.1')
      expect(described_class.channel_layout_for(8)).to eq('7.1')
    end
  end

  describe '.itsoffset_args' do
    it 'returns [] for zero offset' do
      expect(described_class.itsoffset_args(0)).to eq([])
    end

    it 'formats positive and negative offsets to ms precision' do
      expect(described_class.itsoffset_args(0.250)).to eq(['-itsoffset', '0.250'])
      expect(described_class.itsoffset_args(-0.5)).to eq(['-itsoffset', '-0.500'])
    end
  end

  describe '.filter_chain' do
    let(:soxr_caps) do
      Class.new do
        def supports_filter?(name) name == 'aresample_libsoxr' end
      end.new
    end

    it 'starts with resample, then downmix when channels > target' do
      job = make_job(channels: 6, sample_rate: 44_100, output_channels: 2)
      chain = described_class.filter_chain(job, capabilities: soxr_caps)
      expect(chain.first).to start_with('aresample=')
      expect(chain[1]).to start_with('pan=stereo|')
    end

    it 'omits the resampler when source and target sample rates match' do
      job = make_job(channels: 6, sample_rate: 48_000, output_channels: 2)
      chain = described_class.filter_chain(job, capabilities: soxr_caps)
      expect(chain.first).to start_with('pan=stereo|')
    end

    it 'appends loudnorm last when enabled' do
      job = make_job(channels: 2, opts_overrides: { enable_loudnorm: true })
      chain = described_class.filter_chain(job)
      expect(chain.last).to start_with('loudnorm=')
    end

    it 'puts DRC before loudnorm so loudnorm sees the compressed signal' do
      job = make_job(channels: 2, opts_overrides: { enable_drc: true, enable_loudnorm: true })
      chain = described_class.filter_chain(job)
      drc_idx = chain.index { |f| f.start_with?('acompressor=') }
      ln_idx  = chain.index { |f| f.start_with?('loudnorm=') }
      expect(drc_idx).to be < ln_idx
    end

    it 'skips downmix when source ≤ target channels' do
      job = make_job(channels: 2, output_channels: 2)
      chain = described_class.filter_chain(job)
      expect(chain.find { |f| f.start_with?('pan=') }).to be_nil
    end
  end
end

RSpec.describe Jellyfin::Encoding::Bitrate do
  it 'scales per-channel AAC and caps at user setting' do
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264')
    a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'eac3', channels: 6, bit_rate: 640_000)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x', streams: [v, a])
    job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src,
      output_audio_codec: 'aac', output_audio_channels: 2, output_audio_bitrate: 192_000)

    # 2 channels × 64k = 128k, capped at user setting 192k, capped at source 640k → 128k
    expect(described_class.audio_bitrate_for(job)).to eq(128_000)
  end
end

RSpec.describe Jellyfin::Encoding::EncodingHelper do
  let(:caps) do
    Class.new do
      def supports_encoder?(name) %w[libx264 libx265 aac].include?(name) end
      def supports_filter?(_) true end
      def supports_hwaccel?(_) false end
      def supports_decoder?(_) true end
    end.new
  end

  it 'wires channel_layout and -af into audio args when downmixing 5.1 → stereo' do
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264', width: 1920, height: 1080)
    a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'eac3', channels: 6, sample_rate: 48_000)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: [v, a])
    job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src,
      output_audio_codec: 'aac', output_audio_channels: 2)

    helper = described_class.new(caps)
    args = helper.audio_args(job)
    expect(args).to include('-channel_layout', 'stereo')
    af_idx = args.index('-af')
    expect(af_idx).not_to be_nil
    expect(args[af_idx + 1]).to include('pan=stereo|')
  end
end
