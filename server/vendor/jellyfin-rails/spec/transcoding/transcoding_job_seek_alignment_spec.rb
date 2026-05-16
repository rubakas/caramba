require 'spec_helper'
require 'tmpdir'
require 'jellyfin/transcoding/transcoding_job'
require 'jellyfin/output/vod_playlist_generator'

# Regression for the "Resume after a non-zero startTime makes subtitles fire
# a few seconds early" bug (caramba, confirmed 2026-05-16 on The Office UK
# S01E01).
#
# Mechanics: for stream-copy paths the engine's VOD playlist uses
# keyframe-derived VARIABLE segment durations (e.g. 8.008/4.004 alternating
# on a 25fps GOP-of-4 source). When hls.js resumes at video.currentTime=T
# and asks for segment N covering that position, the engine spawns ffmpeg
# at `-ss seek_seconds_for(N)`. The old implementation returned
# `N * segment_length` — which doesn't match the playlist's cumulative
# position for any N>0 on variable playlists. Fast-seek then landed on the
# wrong keyframe and ffmpeg emitted content that hls.js positioned ahead of
# where it belonged via SourceBuffer.timestampOffset. Net effect:
# `video.currentTime` ran ahead of the rendered frames by ~one keyframe
# interval, and external WebVTT cues fired that much early.
RSpec.describe Jellyfin::Transcoding::TranscodingJob, '#seek_seconds_for' do
  let(:root_dir) { Dir.mktmpdir('seek-alignment-') }
  after { FileUtils.rm_rf(root_dir) }

  def build_job(params)
    described_class.new(id: 'seek-test', params: params, root_dir: root_dir)
  end

  context 'for stream-copy on a keyframe-derived variable playlist' do
    # Stand-in for the bug's repro: GOP-of-4.004 (25fps i-frame every 100
    # frames). 30 minutes of source produces an alternating 8.008/4.004
    # cumulative pattern at segment_length=6.
    let(:keyframes) { Array.new(450) { |i| i * 4.004 } }
    let(:total) { keyframes.last + 1.0 }

    let(:expected_durations) do
      Jellyfin::Output::VodPlaylistGenerator.send(
        :compute_segments_from_keyframes,
        keyframe_seconds: keyframes,
        total_duration_seconds: total,
        seek_seconds: 0,
        segment_length_seconds: 6.0
      )
    end

    let(:job) do
      build_job(path: '/fake/file.mkv', video_codec: 'copy', segment_length: 6).tap do |j|
        # `media_source` carries the total duration `compute_segment_durations`
        # needs. We stub the keyframe extractor below so the actual file
        # never gets opened.
        ms = double('MediaSourceInfo', run_time_ticks: (total * 10_000_000).to_i)
        j.media_source = ms
        allow(Jellyfin::Keyframes::Extractor).to receive(:for).with('/fake/file.mkv')
          .and_return(double('keyframes', keyframe_seconds: keyframes))
      end
    end

    it 'lands within the target keyframe window for every segment' do
      # Each `-ss` must be in the half-open window [keyframe_N, keyframe_N+1)
      # — strictly past the target keyframe (because ffmpeg's matroska
      # fast-seek uses strict `<` so an exact match lands one keyframe BACK)
      # and strictly before the next so we don't skip ahead by a keyframe.
      expected_cumulative = [0.0]
      expected_durations.each { |d| expected_cumulative << expected_cumulative.last + d }

      (1...expected_durations.size).each do |n|
        seek = job.seek_seconds_for(n)
        target = expected_cumulative[n]
        next_kf = expected_cumulative[n + 1] || (target + expected_durations[n])
        expect(seek).to be > target,
          "segment #{n}: -ss #{seek} would land on the previous keyframe (target #{target}) — fast-seek strict-less-than"
        expect(seek).to be < next_kf,
          "segment #{n}: -ss #{seek} crosses into the next keyframe at #{next_kf}"
      end
    end

    it 'returns 0 for segment 0 regardless of pattern' do
      expect(job.seek_seconds_for(0)).to eq(0)
    end

    it 'specifically rejects the buggy N * segment_length output' do
      # Segment 1's target keyframe is at 8.008 (the first keyframe ≥ 6),
      # not at 6.0. The seek value must be just past 8.008 so ffmpeg lands
      # on it; bringing back `N * 6` would re-introduce the early-cues
      # regression (since 6.0 lands on the previous keyframe at 4.004).
      seek = job.seek_seconds_for(1)
      expect(seek).to be > 8.008
      expect(seek).to be < 12.012
      expect(seek).not_to eq(6)
    end
  end

  context 'for full-transcode (no keyframe data available)' do
    let(:job) do
      build_job(path: '/fake/file.mkv', video_codec: 'libx264', segment_length: 6).tap do |j|
        # `compute_segment_durations` should bail (video_codec != 'copy')
        # without consulting the extractor — `expect` enforces that.
        expect(Jellyfin::Keyframes::Extractor).not_to receive(:for)
      end
    end

    it 'falls back to N * segment_length for equal-length playlists' do
      # full transcode with `-force_key_frames` emits exact 6s segments,
      # so the multiplication is the right answer in this branch.
      expect(job.seek_seconds_for(0)).to eq(0)
      expect(job.seek_seconds_for(1)).to eq(6)
      expect(job.seek_seconds_for(166)).to eq(996)
    end
  end

  context 'when the keyframe extractor returns nothing (non-MKV / no Cues)' do
    let(:job) do
      build_job(path: '/fake/file.mp4', video_codec: 'copy', segment_length: 6).tap do |j|
        allow(Jellyfin::Keyframes::Extractor).to receive(:for).and_return(nil)
      end
    end

    it 'falls back to N * segment_length so unknown sources still play' do
      expect(job.seek_seconds_for(5)).to eq(30)
    end
  end
end
