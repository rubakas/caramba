require 'spec_helper'

RSpec.describe Jellyfin::Encoding::StreamCopy do
  def make_job(**video_overrides)
    v = Jellyfin::Probing::MediaStream.new(
      index: 0, type: :video, codec: 'h264', width: 1920, height: 1080,
      profile: 'High', level: 41, pixel_format: 'yuv420p',
      sample_aspect_ratio: '1:1', is_interlaced: false,
      video_range_type: 'SDR',
      **video_overrides
    )
    a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac',
      channels: 2, sample_rate: 48_000)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: [v, a])
    Jellyfin::Encoding::EncodingJobInfo.new(media_source: src,
      output_video_codec: 'h264', output_audio_codec: 'aac')
  end

  describe 'check_b_frames' do
    it 'rejects when the source has more b-frames than the client allows' do
      profile = Jellyfin::Playback::ClientProfile.modern_browser
      profile.max_video_b_frames = 2
      job = make_job(has_b_frames: 4)
      result = described_class.video?(job, profile: profile)
      expect(result.reasons).to include(a_string_starting_with('b_frames='))
    end

    it 'passes when the source has fewer b-frames than the cap' do
      profile = Jellyfin::Playback::ClientProfile.modern_browser
      profile.max_video_b_frames = 4
      job = make_job(has_b_frames: 2)
      result = described_class.video?(job, profile: profile)
      expect(result.reasons.grep(/^b_frames=/)).to be_empty
    end

    it 'does not enforce when the profile leaves the cap nil' do
      profile = Jellyfin::Playback::ClientProfile.modern_browser
      profile.max_video_b_frames = nil
      job = make_job(has_b_frames: 9)
      result = described_class.video?(job, profile: profile)
      expect(result.reasons.grep(/^b_frames=/)).to be_empty
    end
  end

  describe 'check_gop_closed' do
    it 'rejects open GOP when the client cannot tolerate it' do
      profile = Jellyfin::Playback::ClientProfile.modern_browser
      profile.supports_open_gop = false
      job = make_job(gop_closed: false)
      result = described_class.video?(job, profile: profile)
      expect(result.reasons).to include('open_gop')
    end

    it 'passes open GOP for clients that explicitly support it' do
      profile = Jellyfin::Playback::ClientProfile.appletv_4k
      profile.supports_open_gop = true
      job = make_job(gop_closed: false)
      result = described_class.video?(job, profile: profile)
      expect(result.reasons).not_to include('open_gop')
    end

    it 'does not reject when GOP state is unknown (nil)' do
      profile = Jellyfin::Playback::ClientProfile.modern_browser
      job = make_job(gop_closed: nil)
      result = described_class.video?(job, profile: profile)
      expect(result.reasons).not_to include('open_gop')
    end
  end

  describe 'check_audio_bit_depth' do
    it 'rejects 24-bit FLAC for a 16-bit-only client' do
      profile = Jellyfin::Playback::ClientProfile.modern_browser
      profile.max_audio_bit_depth = 16
      v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264',
        width: 1920, height: 1080, pixel_format: 'yuv420p', sample_aspect_ratio: '1:1',
        is_interlaced: false, video_range_type: 'SDR')
      a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'flac',
        channels: 2, sample_rate: 96_000, bit_depth: 24)
      src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: [v, a])
      job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src,
        output_video_codec: 'h264', output_audio_codec: 'flac')
      r = described_class.audio?(job, profile: profile)
      expect(r.reasons).to include(a_string_starting_with('audio_bit_depth='))
    end

    it 'passes when source bit depth is within the cap' do
      profile = Jellyfin::Playback::ClientProfile.appletv_4k
      profile.max_audio_bit_depth = 24
      v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264')
      a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'flac',
        channels: 2, sample_rate: 48_000, bit_depth: 16)
      src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x', streams: [v, a])
      job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src,
        output_video_codec: 'h264', output_audio_codec: 'flac')
      r = described_class.audio?(job, profile: profile)
      expect(r.reasons.grep(/^audio_bit_depth=/)).to be_empty
    end
  end
end

RSpec.describe Jellyfin::Probing::GopAnalyzer do
  it 'returns nil for missing files' do
    expect(described_class.closed?('/no/such/file.mkv')).to be_nil
  end

  it 'parses ffprobe JSON and reports closed GOP when all I-frames are key-frames' do
    fake_json = JSON.dump('frames' => [
      { 'pict_type' => 'I', 'key_frame' => 1 },
      { 'pict_type' => 'P', 'key_frame' => 0 },
      { 'pict_type' => 'I', 'key_frame' => 1 }
    ])
    allow(Open3).to receive(:capture3).and_return([fake_json, '', instance_double(Process::Status, success?: true)])
    allow(File).to receive(:exist?).and_return(true)
    expect(described_class.closed?('/fake.mkv', ffprobe_path: 'ffprobe')).to be(true)
  end

  it 'returns false when any I-frame is non-IDR' do
    fake_json = JSON.dump('frames' => [
      { 'pict_type' => 'I', 'key_frame' => 1 },
      { 'pict_type' => 'I', 'key_frame' => 0 }
    ])
    allow(Open3).to receive(:capture3).and_return([fake_json, '', instance_double(Process::Status, success?: true)])
    allow(File).to receive(:exist?).and_return(true)
    expect(described_class.closed?('/fake.mkv', ffprobe_path: 'ffprobe')).to be(false)
  end

  it 'returns nil when ffprobe fails' do
    allow(Open3).to receive(:capture3).and_return(['', 'fail', instance_double(Process::Status, success?: false)])
    allow(File).to receive(:exist?).and_return(true)
    expect(described_class.closed?('/fake.mkv', ffprobe_path: 'ffprobe')).to be_nil
  end
end
