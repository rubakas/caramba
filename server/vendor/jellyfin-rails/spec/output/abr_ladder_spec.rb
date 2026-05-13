require 'spec_helper'

RSpec.describe Jellyfin::Output::AbrLadder do
  describe '.build' do
    it 'returns all rungs ≤ the source height' do
      ladder = described_class.build(source_height: 1080)
      heights = ladder.map(&:height)
      expect(heights).to include(240, 360, 480, 720, 1080)
      expect(heights).not_to include(1440, 2160)
    end

    it 'honors max_height caps from a client profile' do
      ladder = described_class.build(source_height: 2160, max_height: 720)
      expect(ladder.map(&:height).max).to eq(720)
    end

    it 'clamps a variant bitrate to the source bitrate (no upscaling)' do
      ladder = described_class.build(source_height: 1080, source_bitrate: 2_000_000)
      v1080 = ladder.find { |v| v.height == 1080 }
      expect(v1080.video_bitrate).to eq(2_000_000)
    end

    it 'returns a fallback rung when source is unrealistically small' do
      ladder = described_class.build(source_height: 144)
      expect(ladder).not_to be_empty
    end
  end
end
