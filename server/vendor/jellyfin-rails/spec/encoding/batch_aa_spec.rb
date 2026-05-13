require 'spec_helper'

RSpec.describe Jellyfin::Encoding::DecoderFromCodec do
  let(:caps) do
    Class.new do
      def supports_decoder?(name); %w[h264 hevc av1 vp9 aac flac].include?(name); end
    end.new
  end

  it 'returns nil for the upstream blocklist (mp2 / aac_latm / eac3) per cs:646-658' do
    %w[mp2 aac_latm eac3].each do |codec|
      expect(described_class.for(codec, capabilities: caps)).to be_nil
    end
  end

  it 'returns the codec name when capabilities advertise the decoder' do
    expect(described_class.for('h264', capabilities: caps)).to eq('h264')
    expect(described_class.for('aac', capabilities: caps)).to eq('aac')
  end

  it 'returns nil when capabilities lack the decoder (upstream cs:661 SupportsDecoder check)' do
    expect(described_class.for('opus', capabilities: caps)).to be_nil
  end

  it 'returns nil for empty/nil input' do
    expect(described_class.for(nil)).to be_nil
    expect(described_class.for('')).to be_nil
  end

  it 'is case-insensitive on the blocklist' do
    expect(described_class.for('MP2', capabilities: caps)).to be_nil
    expect(described_class.for('AAC_LATM', capabilities: caps)).to be_nil
  end
end

RSpec.describe Jellyfin::Encoding::GraphicalSubCanvas do
  def pgs_job(width:, height:)
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264', width: 1920, height: 1080)
    s = Jellyfin::Probing::MediaStream.new(index: 1, type: :subtitle, codec: 'hdmv_pgs_subtitle',
      width: width, height: height)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: [v, s])
    Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, output_video_codec: 'h264',
      subtitle_stream: s, subtitle_method: :encode)
  end

  it 'emits -canvas_size WxH for PGS subs with known dimensions (upstream cs:985)' do
    args = described_class.args(pgs_job(width: 1920, height: 1080))
    expect(args).to eq(['-canvas_size', '1920x1080'])
  end

  it 'returns [] for DVBSUB (upstream cs:975 exclusion)' do
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264')
    s = Jellyfin::Probing::MediaStream.new(index: 1, type: :subtitle, codec: 'dvbsub', width: 720, height: 576)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.ts', streams: [v, s])
    job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, output_video_codec: 'h264',
      subtitle_stream: s, subtitle_method: :encode)
    expect(described_class.args(job)).to eq([])
  end

  it 'returns [] for text subtitle codecs' do
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264')
    s = Jellyfin::Probing::MediaStream.new(index: 1, type: :subtitle, codec: 'subrip', width: 0, height: 0)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: [v, s])
    job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, output_video_codec: 'h264',
      subtitle_stream: s, subtitle_method: :encode)
    expect(described_class.args(job)).to eq([])
  end

  it 'returns [] when not burning subtitles' do
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264')
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x', streams: [v])
    job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, output_video_codec: 'h264')
    expect(described_class.args(job)).to eq([])
  end

  it 'returns [] when sub dimensions are 0 (no canvas info)' do
    expect(described_class.args(pgs_job(width: 0, height: 0))).to eq([])
  end
end

RSpec.describe Jellyfin::Encoding::InputHwaccelArgs do
  let(:caps) do
    Class.new do
      def supports_encoder?(_); true; end
      def supports_filter?(_); true; end
      def supports_hwaccel?(_); true; end
      def supports_decoder?(_); true; end
    end.new
  end

  def make_job(accel:)
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264')
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x', streams: [v])
    opts = Jellyfin::Encoding::EncodingOptions.new
    opts.hardware_acceleration_type = accel
    Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, options: opts, output_video_codec: 'h264')
  end

  it 'returns [] when hardware_acceleration_type is :none (upstream cs:1006)' do
    expect(described_class.call(job: make_job(accel: :none), capabilities: caps)).to eq([])
  end

  it 'dispatches to NVENC backend.decode_args for :nvenc' do
    args = described_class.call(job: make_job(accel: :nvenc), capabilities: caps)
    expect(args).to include('-hwaccel', 'cuda')
  end

  it 'dispatches to QSV backend for :qsv' do
    args = described_class.call(job: make_job(accel: :qsv), capabilities: caps)
    expect(args).to include('-hwaccel', 'qsv')
  end

  it 'short-circuits to [] for stream-copy (upstream cs:1010)' do
    job = make_job(accel: :nvenc)
    job.instance_variable_set(:@output_video_codec, 'copy')
    expect(described_class.call(job: job, capabilities: caps)).to eq([])
  end
end

RSpec.describe Jellyfin::Encoding::DynamicHdrStatus do
  def dv_job(tonemap:, copy: false)
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'hevc',
      video_range_type: 'DOVI', dovi_profile: 8, dovi_rpu_present: true)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: [v])
    opts = Jellyfin::Encoding::EncodingOptions.new
    opts.enable_tonemapping = tonemap
    Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, options: opts,
      output_video_codec: copy ? 'copy' : 'h265')
  end

  it 'dovi_removed? is true when source has DV and tonemap is on' do
    expect(described_class.dovi_removed?(dv_job(tonemap: true))).to be(true)
  end

  it 'dovi_removed? is false for stream-copy (upstream cs:1471)' do
    expect(described_class.dovi_removed?(dv_job(tonemap: true, copy: true))).to be(false)
  end

  it 'dovi_removed? is false when source has no DV' do
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'hevc')
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x', streams: [v])
    job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, output_video_codec: 'h265')
    expect(described_class.dovi_removed?(job)).to be(false)
  end

  it 'hdr10plus_removed? mirrors dovi_removed? for HDR10+ sources' do
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'hevc',
      hdr10plus_present: true, video_range_type: 'HDR10')
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: [v])
    opts = Jellyfin::Encoding::EncodingOptions.new
    opts.enable_tonemapping = true
    job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, options: opts, output_video_codec: 'h265')
    expect(described_class.hdr10plus_removed?(job)).to be(true)
  end
end

RSpec.describe Jellyfin::Encoding::BitStreamArgs do
  def make_job(video_codec: 'h264', audio_codec: 'aac')
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: video_codec)
    a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: audio_codec)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x', streams: [v, a])
    Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, output_video_codec: video_codec)
  end

  it 'emits h264_mp4toannexb for H.264 video (upstream cs:1498)' do
    expect(described_class.call(job: make_job, stream_type: :video)).to eq(['-bsf:v', 'h264_mp4toannexb'])
  end

  it 'emits aac_adtstoasc for AAC audio (upstream cs:1504)' do
    expect(described_class.call(job: make_job, stream_type: :audio)).to eq(['-bsf:a', 'aac_adtstoasc'])
  end

  it 'emits hevc_mp4toannexb for HEVC video (upstream cs:1509)' do
    expect(described_class.call(job: make_job(video_codec: 'hevc'), stream_type: :video)).to eq(['-bsf:v', 'hevc_mp4toannexb'])
  end

  it 'appends hevc_metadata=remove_dovi=1 when DV is being stripped (upstream cs:1521)' do
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'hevc',
      video_range_type: 'DOVI', dovi_profile: 8, dovi_rpu_present: true)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x', streams: [v])
    opts = Jellyfin::Encoding::EncodingOptions.new
    opts.enable_tonemapping = true
    job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, options: opts, output_video_codec: 'h265')
    args = described_class.call(job: job, stream_type: :video)
    expect(args[-1]).to include('remove_dovi=1')
  end

  describe '.audio_call (upstream cs:1551)' do
    it 'emits the audio bsf only when going from mpegts→mp4 family' do
      args = described_class.audio_call(job: make_job, segment_container: 'mp4', media_source_container: 'ts')
      expect(args).to eq(['-bsf:a', 'aac_adtstoasc'])
    end

    it 'returns [] for mpegts→mpegts (no container switch)' do
      args = described_class.audio_call(job: make_job, segment_container: 'ts', media_source_container: 'ts')
      expect(args).to eq([])
    end
  end
end

RSpec.describe Jellyfin::Encoding::HlsKeyframes do
  def make_job(framerate: 24.0)
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264', frame_rate: framerate)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x', streams: [v])
    Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, output_video_codec: 'h264')
  end

  it 'libx264 → -force_key_frames + -sc_threshold:v:0 0 (upstream cs:2009)' do
    args = described_class.args(job: make_job, codec: 'libx264', segment_length: 6)
    expect(args).to include('-force_key_frames:0', 'expr:gte(t,n_forced*6)')
    expect(args).to include('-sc_threshold:v:0', '0')
  end

  it 'h264_nvenc → -g:v:0 N + -keyint_min:v:0 N (GOP-only encoders, upstream cs:1986)' do
    args = described_class.args(job: make_job(framerate: 24.0), codec: 'h264_nvenc', segment_length: 6)
    expect(args).to include('-g:v:0', '144')
    expect(args).to include('-keyint_min:v:0', '144')
  end

  it 'h264_vaapi uses expr-based keyframes but no sc_threshold' do
    args = described_class.args(job: make_job, codec: 'h264_vaapi', segment_length: 6)
    expect(args).to include('-force_key_frames:0')
    expect(args).not_to include('-sc_threshold:v:0')
  end

  it 'AMD HEVC VAAPI emits -flags:v -global_header (upstream cs:2019)' do
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'hevc', frame_rate: 24.0)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x', streams: [v])
    opts = Jellyfin::Encoding::EncodingOptions.new
    opts.vaapi_device = '/dev/dri/renderD128/amd'
    job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, options: opts, output_video_codec: 'hevc')
    args = described_class.args(job: job, codec: 'hevc_vaapi', segment_length: 6)
    expect(args).to include('-flags:v', '-global_header')
  end
end

RSpec.describe Jellyfin::Encoding::NegativeMap do
  let(:caps) do
    Class.new do
      def supports_encoder?(_); true; end
      def supports_filter?(_); true; end
      def supports_hwaccel?(_); false; end
      def supports_decoder?(_); true; end
    end.new
  end

  it 'emits -map -0:N when the filter chain uses -filter_complex (upstream cs:3126)' do
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264')
    a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac')
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x', streams: [v, a])
    job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, output_video_codec: 'h264')
    args = described_class.args(job: job, video_process_filters: '-filter_complex [0:v][0:s]overlay=...')
    expect(args).to eq(['-map', '-0:0'])
  end

  it 'returns [] when no -filter_complex is present (regular -vf chain)' do
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264')
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x', streams: [v])
    job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, output_video_codec: 'h264')
    expect(described_class.args(job: job, video_process_filters: '-vf scale=1280:720')).to eq([])
  end
end

RSpec.describe Jellyfin::Encoding::ColorPropsOverride do
  def make_job(color_transfer: 'smpte2084')
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'hevc', color_transfer: color_transfer)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: [v])
    Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, output_video_codec: 'h265')
  end

  it 'tonemap_available=true → HDR10 setparams (upstream cs:6300)' do
    out = described_class.call(job: make_job, tonemap_available: true)
    expect(out).to include('color_trc=smpte2084')
    expect(out).to include('color_primaries=bt2020')
    expect(out).to include('colorspace=bt2020nc')
  end

  it 'HLG → arib-std-b67 setparams (upstream cs:6296)' do
    out = described_class.call(job: make_job(color_transfer: 'arib-std-b67'), tonemap_available: true)
    expect(out).to include('color_trc=arib-std-b67')
  end

  it 'tonemap_available=false → SDR bt709 setparams (upstream cs:6303)' do
    out = described_class.call(job: make_job, tonemap_available: false)
    expect(out).to eq('setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709')
  end

  it 'tonemapping_range=tv adds range=tv suffix' do
    job = make_job
    job.options.tonemapping_range = 'tv'
    out = described_class.call(job: job, tonemap_available: false)
    expect(out).to end_with(':range=tv')
  end
end
