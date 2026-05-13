require 'spec_helper'

RSpec.describe Jellyfin::MediaEncoder::Probe do
  describe '.from_path with a real fixture' do
    let(:fixture) { File.join(FIXTURE_PATH, 'sample.mp4') }

    before do
      skip 'fixture missing' unless File.exist?(fixture)
      Jellyfin::Rails.configure do |c|
        c.ffprobe_path = ENV.fetch('TEST_FFPROBE_PATH', '/Applications/Jellyfin.app/Contents/MacOS/ffprobe')
        c.allowed_paths = [FIXTURE_PATH]
      end
      skip 'ffprobe not present' unless File.executable?(Jellyfin::Rails.configuration.ffprobe_path)
    end

    subject(:info) { described_class.from_path(fixture, cache: Jellyfin::MediaEncoder::Probe::NullCache.instance) }

    it 'returns a MediaSourceInfo' do
      expect(info).to be_a(Jellyfin::Probing::MediaSourceInfo)
    end

    it 'has a video stream with the expected codec + size' do
      v = info.default_video_stream
      expect(v.codec).to eq('h264')
      expect(v.width).to eq(320)
      expect(v.height).to eq(240)
    end

    it 'has an audio stream' do
      a = info.default_audio_stream
      expect(a.codec).to eq('aac')
      expect(a.sample_rate).to eq(44_100)
    end

    it 'measures duration close to 3 seconds' do
      expect(info.duration_seconds).to be_within(0.5).of(3.0)
    end

    it 'normalizes the mp4 container' do
      expect(info.container).to eq('mp4')
    end

    it 'raises ProbeFailed on a missing file' do
      expect { described_class.new('/nonexistent/path.mkv').call }
        .to raise_error(Jellyfin::MediaEncoder::Probe::ProbeFailed)
    end
  end
end
