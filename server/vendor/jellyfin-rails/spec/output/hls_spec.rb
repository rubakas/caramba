require 'spec_helper'

RSpec.describe Jellyfin::Output::Hls do
  describe '.output_args' do
    it 'emits classic mpegts segments by default' do
      args = described_class.output_args(
        playlist_path: '/tmp/p.m3u8',
        segment_template: '/tmp/%d.ts',
        segment_length: 6
      )
      expect(args).to include('-hls_segment_type', 'mpegts')
      expect(args).to include('-hls_segment_filename', '/tmp/%d.ts')
      expect(args.last).to eq('/tmp/p.m3u8')
    end

    it 'switches to fmp4 segments with an init file when format is :fmp4' do
      args = described_class.output_args(
        playlist_path: '/tmp/p.m3u8',
        segment_template: '/tmp/%d.m4s',
        segment_length: 4,
        segment_format: :fmp4,
        init_segment_path: '/tmp/init.mp4'
      )
      expect(args).to include('-hls_segment_type', 'fmp4')
      expect(args).to include('-hls_fmp4_init_filename', 'init.mp4')
    end
  end

  describe '.master_playlist' do
    it 'emits CODECS + RESOLUTION attributes per variant' do
      pls = described_class.master_playlist(variants: [
        { uri: '720p/index.m3u8', bandwidth: 2_800_000, codecs: 'avc1.640028,mp4a.40.2', resolution: '1280x720', name: '720p' },
        { uri: '1080p/index.m3u8', bandwidth: 5_000_000, codecs: 'avc1.640028,mp4a.40.2', resolution: '1920x1080', name: '1080p' }
      ])
      expect(pls).to include('#EXTM3U')
      expect(pls).to include('BANDWIDTH=2800000')
      expect(pls).to include('CODECS="avc1.640028,mp4a.40.2"')
      expect(pls).to include('RESOLUTION=1280x720')
      expect(pls).to include('720p/index.m3u8')
    end
  end

  describe '.iframe_playlist' do
    it 'emits #EXT-X-I-FRAME-STREAM-INF entries with URI inside the tag' do
      out = described_class.iframe_playlist(variants: [
        { uri: '720p/iframes.m3u8', bandwidth: 200_000, codecs: 'avc1.640028', resolution: '1280x720' }
      ])
      expect(out).to include('#EXT-X-I-FRAME-STREAM-INF:')
      expect(out).to include('URI="720p/iframes.m3u8"')
      expect(out).to include('BANDWIDTH=200000')
    end
  end
end
