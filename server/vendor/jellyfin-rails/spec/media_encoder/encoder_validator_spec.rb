require 'spec_helper'
require 'jellyfin/media_encoder/encoder_validator'

RSpec.describe Jellyfin::MediaEncoder::EncoderValidator do
  describe '#probe' do
    let(:ffmpeg_path) { ENV.fetch('TEST_FFMPEG_PATH', 'ffmpeg') }
    subject(:caps) { described_class.new(ffmpeg_path).probe }

    it 'detects an ffmpeg version' do
      skip 'ffmpeg not on PATH' unless system("#{ffmpeg_path} -version > /dev/null 2>&1")
      expect(caps.version).to match(/\A\d+\.\d+/)
    end

    it 'enumerates encoders, decoders, filters, hwaccels' do
      skip 'ffmpeg not on PATH' unless system("#{ffmpeg_path} -version > /dev/null 2>&1")
      expect(caps.encoders).to include('aac')
      expect(caps.decoders).to include('h264')
      expect(caps.filters).to include('scale')
      expect(caps.supports_encoder?('libx264')).to be(true).or be(false) # build-dependent
    end
  end
end
