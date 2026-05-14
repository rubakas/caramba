require 'spec_helper'
require 'jellyfin/output/vod_playlist_generator'

RSpec.describe Jellyfin::Output::VodPlaylistGenerator do
  describe '.build' do
    it 'emits a complete VOD playlist with PLAYLIST-TYPE:VOD + ENDLIST' do
      out = described_class.build(
        total_duration_seconds: 18.0,
        segment_length_seconds: 6.0
      )

      # Safari's native HLS engine treats EVENT-without-ENDLIST as a live
      # stream and refuses to start playback for transcodes that take
      # >1-2s to produce the first segments. Both markers below are what
      # tell Safari this is finite VOD content. Regression for the issue
      # where ffmpeg's in-progress playlist was being served verbatim.
      expect(out).to start_with('#EXTM3U')
      expect(out).to include('#EXT-X-PLAYLIST-TYPE:VOD')
      expect(out).to include('#EXT-X-VERSION:3') # mpegts → version 3
      expect(out).to include('#EXT-X-TARGETDURATION:6')
      expect(out).to include('#EXT-X-MEDIA-SEQUENCE:0')
      expect(out).to include('#EXT-X-INDEPENDENT-SEGMENTS')
      expect(out).to end_with("#EXT-X-ENDLIST\n")
    end

    it 'lists every segment from 0.ts upward' do
      out = described_class.build(
        total_duration_seconds: 18.0,
        segment_length_seconds: 6.0
      )

      # 18s / 6s = 3 whole segments, no remainder
      expect(out).to include("#EXTINF:6.000000,\n0.ts")
      expect(out).to include("#EXTINF:6.000000,\n1.ts")
      expect(out).to include("#EXTINF:6.000000,\n2.ts")
      expect(out).not_to include('3.ts')
    end

    it 'appends a short final segment for the runtime remainder' do
      out = described_class.build(
        total_duration_seconds: 14.5,
        segment_length_seconds: 6.0
      )

      expect(out).to include("#EXTINF:6.000000,\n0.ts")
      expect(out).to include("#EXTINF:6.000000,\n1.ts")
      expect(out).to include("#EXTINF:2.500000,\n2.ts")
      expect(out).not_to include('3.ts')
    end

    it 'subtracts seek offset from the total duration' do
      out = described_class.build(
        total_duration_seconds: 30.0,
        segment_length_seconds: 6.0,
        seek_seconds: 18.0
      )

      # ffmpeg's -ss makes segment 0 correspond to t=18s; the playlist
      # only covers the remaining 12s starting from segment 0.
      expect(out).to include("#EXTINF:6.000000,\n0.ts")
      expect(out).to include("#EXTINF:6.000000,\n1.ts")
      expect(out).not_to include('2.ts')
    end

    it 'uses HLS version 7 + .m4s extension for fmp4 segments' do
      out = described_class.build(
        total_duration_seconds: 12.0,
        segment_length_seconds: 6.0,
        segment_extension: 'm4s',
        container: 'mp4'
      )

      expect(out).to include('#EXT-X-VERSION:7')
      expect(out).to include('0.m4s')
      expect(out).to include('1.m4s')
    end

    it 'returns nil when seek meets or exceeds total duration' do
      expect(described_class.build(
        total_duration_seconds: 10.0,
        segment_length_seconds: 6.0,
        seek_seconds: 10.0
      )).to be_nil
    end
  end

  describe '.compute_equal_length_segments' do
    it 'emits equal-length segments with a remainder tail' do
      segs = described_class.compute_equal_length_segments(14.5, 6.0)
      expect(segs).to eq([ 6.0, 6.0, 2.5 ])
    end

    it 'drops a sub-1ms tail to avoid demuxer-rejected micro-segments' do
      segs = described_class.compute_equal_length_segments(12.0005, 6.0)
      expect(segs).to eq([ 6.0, 6.0 ])
    end
  end
end
