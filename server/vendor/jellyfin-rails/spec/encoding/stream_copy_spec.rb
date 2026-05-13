require 'spec_helper'

RSpec.describe Jellyfin::Encoding::StreamCopy do
  def make_job(video:, audio:, **ov)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', container: 'mkv', streams: [video, audio])
    Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, **ov)
  end

  let(:browser) { Jellyfin::Playback::ClientProfile.modern_browser }

  describe '.video?' do
    it 'returns eligible for matching h264 + same bitrate + same height' do
      v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264',
        profile: 'High', level: 41, width: 1920, height: 1080, frame_rate: 24.0,
        bit_rate: 4_000_000, pixel_format: 'yuv420p', sample_aspect_ratio: '1:1',
        is_interlaced: false, video_range_type: 'SDR')
      a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac', channels: 2, sample_rate: 48_000)
      job = make_job(video: v, audio: a, output_video_codec: 'h264', output_video_bitrate: 5_000_000)

      r = described_class.video?(job, profile: browser)
      expect(r).to be_eligible
      expect(r.reasons).to be_empty
    end

    it 'rejects when input codec is hevc but output is h264' do
      v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'hevc',
        width: 1920, height: 1080, video_range_type: 'SDR', sample_aspect_ratio: '1:1',
        pixel_format: 'yuv420p', is_interlaced: false)
      a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac', channels: 2, sample_rate: 48_000)
      job = make_job(video: v, audio: a, output_video_codec: 'h264')
      r = described_class.video?(job, profile: browser)
      expect(r).not_to be_eligible
      expect(r.reasons.first).to start_with('codec_mismatch')
    end

    it 'rejects on yuv444 pixel format' do
      v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264',
        width: 1920, height: 1080, pixel_format: 'yuv444p', sample_aspect_ratio: '1:1',
        is_interlaced: false, video_range_type: 'SDR')
      a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac', channels: 2, sample_rate: 48_000)
      job = make_job(video: v, audio: a, output_video_codec: 'h264')
      r = described_class.video?(job, profile: browser)
      expect(r.reasons).to include('pixel_format_yuv444')
    end

    it 'rejects HDR when client cannot render HDR' do
      v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'hevc',
        width: 3840, height: 2160, pixel_format: 'yuv420p10le', sample_aspect_ratio: '1:1',
        is_interlaced: false, video_range: 'HDR', video_range_type: 'HDR10')
      a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac', channels: 2, sample_rate: 48_000)
      job = make_job(video: v, audio: a, output_video_codec: 'hevc')
      r = described_class.video?(job, profile: browser)
      expect(r.reasons).to include('hdr')
    end

    it 'rejects 10-bit when client lacks 10-bit support' do
      v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264',
        width: 1920, height: 1080, pixel_format: 'yuv420p10le', bit_depth: 10,
        sample_aspect_ratio: '1:1', is_interlaced: false, video_range_type: 'SDR')
      a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac', channels: 2, sample_rate: 48_000)
      job = make_job(video: v, audio: a, output_video_codec: 'h264')
      r = described_class.video?(job, profile: browser)
      expect(r.reasons).to include('bit_depth_10_unsupported')
    end

    it 'rejects interlaced for clients without interlace support' do
      v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264',
        width: 1920, height: 1080, pixel_format: 'yuv420p', sample_aspect_ratio: '1:1',
        is_interlaced: true, field_order: 'tt', video_range_type: 'SDR')
      a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac', channels: 2, sample_rate: 48_000)
      job = make_job(video: v, audio: a, output_video_codec: 'h264')
      r = described_class.video?(job, profile: browser)
      expect(r.reasons).to include('interlaced')
    end

    it 'rejects when video exceeds client max height' do
      v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264',
        width: 3840, height: 2160, pixel_format: 'yuv420p', sample_aspect_ratio: '1:1',
        is_interlaced: false, video_range_type: 'SDR')
      a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac', channels: 2, sample_rate: 48_000)
      job = make_job(video: v, audio: a, output_video_codec: 'h264')
      r = described_class.video?(job, profile: browser)
      expect(r.reasons.any? { |s| s.include?('client_max_height') }).to be(true)
    end
  end

  describe '.audio?' do
    it 'rejects when input has too many channels' do
      v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264',
        width: 1920, height: 1080, video_range_type: 'SDR', pixel_format: 'yuv420p',
        sample_aspect_ratio: '1:1', is_interlaced: false)
      a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac', channels: 8, sample_rate: 48_000)
      job = make_job(video: v, audio: a, output_audio_codec: 'aac', output_audio_channels: 2)
      r = described_class.audio?(job, profile: browser)
      expect(r.reasons.any? { |s| s.include?('audio_channels') }).to be(true)
    end

    it 'rejects when audio sample rate differs from target' do
      v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264',
        width: 1920, height: 1080, video_range_type: 'SDR', pixel_format: 'yuv420p',
        sample_aspect_ratio: '1:1', is_interlaced: false)
      a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac', channels: 2, sample_rate: 44_100)
      job = make_job(video: v, audio: a, output_audio_codec: 'aac', output_audio_sample_rate: 48_000)
      r = described_class.audio?(job, profile: browser)
      expect(r.reasons.any? { |s| s.include?('audio_sample_rate') }).to be(true)
    end
  end
end

RSpec.describe Jellyfin::Encoding::Framerate do
  it 'snaps near-standard rates to their nominal value' do
    expect(described_class.normalize(23.97)).to be_within(0.01).of(24000.0 / 1001.0)
    expect(described_class.normalize(29.95)).to be_within(0.01).of(30000.0 / 1001.0)
    expect(described_class.normalize(59.97)).to be_within(0.01).of(60000.0 / 1001.0)
  end

  it 'leaves exotic rates alone (rounded)' do
    expect(described_class.normalize(48.0)).to eq(48.0)
  end

  it 'halves to preserve cadence when source > max' do
    expect(described_class.clamp(60.0, max: 30)).to be_within(0.01).of(30.0)
    expect(described_class.clamp(59.94, max: 30)).to be_within(0.01).of(30000.0 / 1001.0)
    expect(described_class.clamp(50.0, max: 25)).to eq(25.0)
  end

  it 'returns rate unchanged if already ≤ max' do
    expect(described_class.clamp(24.0, max: 30)).to eq(24.0)
  end

  it 'emits ffmpeg -r arg' do
    expect(described_class.ffmpeg_args(24.0)).to eq(['-r', '24'])
  end
end

RSpec.describe Jellyfin::Encoding::ProfileMapping do
  def make_job(bit_depth:, codec: 'h264')
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264',
      width: 1920, height: 1080, pixel_format: bit_depth == 10 ? 'yuv420p10le' : 'yuv420p',
      bit_depth: bit_depth)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x', streams: [v])
    Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, output_video_codec: codec)
  end

  it 'picks high for 8-bit H.264' do
    expect(described_class.for_h264(make_job(bit_depth: 8))).to eq('high')
  end

  it 'picks high10 for 10-bit H.264' do
    expect(described_class.for_h264(make_job(bit_depth: 10))).to eq('high10')
  end

  it 'picks main for 8-bit H.265' do
    expect(described_class.for_h265(make_job(bit_depth: 8, codec: 'h265'))).to eq('main')
  end

  it 'picks main10 for 10-bit H.265' do
    expect(described_class.for_h265(make_job(bit_depth: 10, codec: 'h265'))).to eq('main10')
  end

  it 'picks main12 for 12-bit H.265' do
    expect(described_class.for_h265(make_job(bit_depth: 12, codec: 'h265'))).to eq('main12')
  end
end
