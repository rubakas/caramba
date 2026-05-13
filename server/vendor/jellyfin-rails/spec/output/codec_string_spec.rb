require 'spec_helper'

RSpec.describe Jellyfin::Output::CodecString do
  describe '.for' do
    it 'produces a typical AVC + AAC string for a 1080p High 4.0 source' do
      s = described_class.for(video_codec: 'h264', audio_codec: 'aac', profile: 'high', level: 4.0)
      expect(s).to eq('avc1.640028,mp4a.40.2')
    end

    it 'encodes level 4.1 as 0x29 (41 decimal → 29 hex)' do
      s = described_class.for(video_codec: 'h264', audio_codec: 'aac', profile: 'high', level: 4.1)
      expect(s).to eq('avc1.640029,mp4a.40.2')
    end

    it 'switches video portion for HEVC main10' do
      s = described_class.for(video_codec: 'hevc', audio_codec: 'aac', profile: 'main10', level: 5.1)
      expect(s).to start_with('hev1.2.4.')
      expect(s).to end_with(',mp4a.40.2')
    end

    it 'maps AC-3 / E-AC-3 to their RFC 6381 names' do
      expect(described_class.audio_string('ac3')).to eq('ac-3')
      expect(described_class.audio_string('eac3')).to eq('ec-3')
    end

    it 'omits audio segment when codec is unknown' do
      s = described_class.for(video_codec: 'h264', audio_codec: 'unknown', profile: 'high', level: 4.0)
      expect(s).not_to include(',')
    end
  end
end
