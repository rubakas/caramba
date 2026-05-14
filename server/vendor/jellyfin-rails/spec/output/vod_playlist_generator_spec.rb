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

    it 'emits #EXT-X-MAP when given an init_segment_uri' do
      # Caramba's HEVC stream-copy path emits `-hls_fmp4_init_filename
      # -1.mp4` and serves it through the engine's `init_segment`
      # route. Safari needs the #EXT-X-MAP line before any media
      # segment so it can pick up codec setup boxes.
      out = described_class.build(
        total_duration_seconds: 12.0,
        segment_length_seconds: 6.0,
        segment_extension: 'mp4',
        container: 'mp4',
        init_segment_uri: '-1.mp4'
      )

      expect(out).to include('#EXT-X-VERSION:7')
      expect(out).to include('#EXT-X-MAP:URI="-1.mp4"')
      expect(out).to include("0.mp4")
      # EXT-X-MAP must appear BEFORE any segment EXTINF/uri.
      map_pos = out.index('#EXT-X-MAP')
      seg_pos = out.index('0.mp4')
      expect(map_pos).to be < seg_pos
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

  describe '.compute_segments_from_keyframes' do
    # Mirrors upstream DynamicHlsPlaylistGenerator.ComputeSegments.
    # The walk emits a new segment cut every time the next keyframe is
    # the first one to cross the running `desired_cut_time` threshold.
    it 'cuts at the first keyframe past each segment boundary' do
      # Keyframes at 0, 2.5, 5, 7.5, 10, 12.5 — typical streaming GOP.
      segs = described_class.compute_segments_from_keyframes(
        keyframe_seconds: [ 0, 2.5, 5, 7.5, 10, 12.5 ],
        total_duration_seconds: 14.0,
        seek_seconds: 0,
        segment_length_seconds: 6.0
      )
      # First cut at 7.5 (first kf >= 6) → segment 0 length 7.5s.
      # Next at 12.5 (first kf >= 13.5? no, 12.5 < 13.5) — wait,
      # desired_cut after first cut = 6 + 6 = 12, so 12.5 >= 12 cuts.
      # Length: 12.5 - 7.5 = 5s. Tail: 14.0 - 12.5 = 1.5s.
      expect(segs).to eq([ 7.5, 5.0, 1.5 ])
    end

    it 'reproduces the variable-segment pattern an x265 rip produces' do
      # Reproduces the durations the user's comment lists as the typical
      # x265-rip adaptive-GOP shape: 9.1s, 4.0s, 8.7s, 8.3s, ...
      # Keyframes at those running totals.
      kfs = [ 0, 9.1, 13.1, 21.8, 30.1 ]
      segs = described_class.compute_segments_from_keyframes(
        keyframe_seconds: kfs,
        total_duration_seconds: 30.1,
        seek_seconds: 0,
        segment_length_seconds: 6.0
      )
      expect(segs.map { |s| s.round(1) }).to eq([ 9.1, 4.0, 8.7, 8.3 ])
    end

    it 'shifts keyframe coordinates into the post-seek timeline' do
      # ffmpeg `-ss 280` snaps to the first keyframe at/after 280s.
      # The playlist's segment 0 then sits at t=0 in the post-seek view.
      kfs = [ 0, 100, 200, 280, 286.5, 293, 299.5 ]
      segs = described_class.compute_segments_from_keyframes(
        keyframe_seconds: kfs,
        total_duration_seconds: 300.0,
        seek_seconds: 280.0,
        segment_length_seconds: 6.0
      )
      # Post-seek kfs: [0, 6.5, 13.0, 19.5]
      # Cuts at 6.5, 13.0, 19.5 (each ≥ 6, 12, 18 respectively).
      # Lengths: 6.5, 6.5, 6.5. Tail: 20.0 - 19.5 = 0.5.
      expect(segs.map { |s| s.round(1) }).to eq([ 6.5, 6.5, 6.5, 0.5 ])
    end

    it 'returns [] when seek skips past every keyframe' do
      segs = described_class.compute_segments_from_keyframes(
        keyframe_seconds: [ 0, 5, 10 ],
        total_duration_seconds: 15.0,
        seek_seconds: 20.0,
        segment_length_seconds: 6.0
      )
      expect(segs).to eq([])
    end
  end

  describe '.build with keyframe_seconds' do
    it 'derives EXTINF from real keyframe boundaries' do
      out = described_class.build(
        total_duration_seconds: 14.0,
        segment_length_seconds: 6.0,
        keyframe_seconds: [ 0, 2.5, 5, 7.5, 10, 12.5 ]
      )

      # First segment is 7.5s (longer than nominal 6.0); TARGETDURATION
      # must round up the MAX segment length — Safari rejects a playlist
      # whose target is shorter than any EXTINF.
      expect(out).to include("#EXTINF:7.500000,\n0.ts")
      expect(out).to include("#EXTINF:5.000000,\n1.ts")
      expect(out).to include("#EXTINF:1.500000,\n2.ts")
      expect(out).to include('#EXT-X-TARGETDURATION:8')
    end

    it 'falls back to equal-length when keyframe_seconds is empty' do
      out = described_class.build(
        total_duration_seconds: 12.0,
        segment_length_seconds: 6.0,
        keyframe_seconds: []
      )
      expect(out).to include("#EXTINF:6.000000,\n0.ts")
      expect(out).to include("#EXTINF:6.000000,\n1.ts")
      expect(out).to include('#EXT-X-TARGETDURATION:6')
    end
  end
end
