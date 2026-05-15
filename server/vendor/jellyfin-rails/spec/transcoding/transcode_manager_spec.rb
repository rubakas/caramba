require 'spec_helper'
require 'tmpdir'

RSpec.describe Jellyfin::Transcoding::TranscodeManager do
  let(:fixture) { File.join(FIXTURE_PATH, 'sample.mp4') }
  let(:tmp_root) { Dir.mktmpdir('jelly-test-') }

  before do
    skip 'fixture missing' unless File.exist?(fixture)
    ffmpeg = ENV.fetch('TEST_FFMPEG_PATH', '/Applications/Jellyfin.app/Contents/MacOS/ffmpeg')
    skip 'ffmpeg not present' unless File.executable?(ffmpeg)

    described_class.reset!
    Jellyfin::Rails.configure do |c|
      c.ffmpeg_path = ffmpeg
      c.transcode_dir = tmp_root
      c.token_secret = 'test-secret'
      c.idle_timeout = 60
      c.segment_length = 1
    end
  end

  after do
    described_class.reset!
    FileUtils.rm_rf(tmp_root)
  end

  it 'transcodes the fixture into an HLS playlist + segments' do
    manager = described_class.instance
    job = manager.ensure_started(
      id: 'job-test-1',
      params: { path: fixture, segment_length: 1, video_bitrate: 500_000 }
    )

    target_segment = job.segment_path(2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
    until File.exist?(target_segment) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.1
    end

    expect(File).to exist(job.playlist_path), -> { File.read(job.stderr_path) }
    expect(File.read(job.playlist_path)).to include('#EXTM3U')
    expect(Dir[File.join(job.dir, '*.ts')]).not_to be_empty

    manager.stop!(job.id)
    expect(job.alive?).to be(false)
  end

  it 'returns the same job for repeated ensure_started with the same id' do
    manager = described_class.instance
    j1 = manager.ensure_started(id: 'same', params: { path: fixture, segment_length: 1 })
    j2 = manager.ensure_started(id: 'same', params: { path: fixture, segment_length: 1 })
    expect(j2).to equal(j1)
    manager.stop!('same')
  end

  # Regression: ref_count grew by one on each ensure_started — which happens
  # on every segment request — and never decremented on HTTP-level client
  # disconnect. The previous reaper guard `next if job.ref_count.positive?`
  # therefore skipped every idle job forever, leaving ffmpeg orphans (often
  # SIGSTOP'd by the throttler) pegged in state T+ until the box was
  # restarted. Reap_idle now uses HTTP-activity (idle_for) only — matches
  # upstream's PingTimer / OnTranscodeKillTimerStopped (TranscodeManager.cs:174).
  it 'reaps an idle job even when ref_count is still positive (HTTP-disconnect heuristic)' do
    manager = described_class.instance
    Jellyfin::Rails.configuration.idle_timeout = 0 # force idle threshold to fire
    job = manager.ensure_started(id: 'orphan', params: { path: fixture, segment_length: 1 })
    # Simulate the orphan pattern: client kept refcount positive but is
    # no longer fetching segments.
    job.attach!; job.attach!; job.attach!
    expect(job.ref_count).to be >= 4
    sleep 0.1 # ensure idle_for advances past idle_timeout=0
    manager.send(:reap_idle)
    expect(manager.send(:find, 'orphan')).to be_nil
    expect(job.alive?).to be(false)
  end
end

# Stream lookup semantics: track-selection params from the controller
# carry the GLOBAL ffprobe stream index (`s.index`), matching upstream
# Jellyfin's `AudioStreamIndex` / `VideoStreamIndex` / `SubtitleStreamIndex`.
# Upstream resolves these via `EncodingHelper.GetMediaStream`, which
# filters by stream type and picks the one whose `.Index` matches —
# NOT the Nth element of the per-type sublist. Regression for the case
# of multi-audio MKVs (typical of foreign-language releases like
# EEAAO with UKR_ENG): the controller picks `audio_track=3` (global
# stream index of the matched English AC-3), the engine previously did
# `audio_streams[3]` and either picked the wrong audio or fell through
# to default — never the audio the user asked for.
RSpec.describe Jellyfin::Transcoding::TranscodeManager, 'stream lookup' do
  let(:manager) { Jellyfin::Transcoding::TranscodeManager.new }

  def stream(index, type, **rest)
    Jellyfin::Probing::MediaStream.new(index: index, type: type, **rest)
  end

  let(:source) do
    Jellyfin::Probing::MediaSourceInfo.new(
      id: 'eeaao', path: '/x.mkv', container: 'mkv', run_time_ticks: 0,
      streams: [
        stream(0, :video, codec: 'hevc'),
        stream(1, :audio, codec: 'ac3', channels: 6, language: 'ukr'),
        stream(2, :audio, codec: 'ac3', channels: 2, language: 'ukr'),
        stream(3, :audio, codec: 'ac3', channels: 2, language: 'eng'),
        stream(4, :audio, codec: 'ac3', channels: 6, language: 'eng'),
        stream(5, :subtitle, codec: 'subrip', language: 'eng'),
        stream(6, :subtitle, codec: 'hdmv_pgs_subtitle', language: 'ukr')
      ]
    )
  end

  it 'select_audio_stream looks up by global ffprobe stream index' do
    picked = manager.send(:select_audio_stream, source, 3)
    expect(picked.index).to eq(3)
    expect(picked.language).to eq('eng')
    expect(picked.channels).to eq(2)
  end

  it 'select_video_stream looks up by global ffprobe stream index' do
    picked = manager.send(:select_video_stream, source, 0)
    expect(picked.index).to eq(0)
    expect(picked.codec).to eq('hevc')
  end

  it 'select_subtitle_stream looks up by global ffprobe stream index' do
    picked = manager.send(:select_subtitle_stream, source, 5)
    expect(picked.index).to eq(5)
    expect(picked.codec).to eq('subrip')
  end

  it 'select_audio_stream falls back to default when global index has no match' do
    picked = manager.send(:select_audio_stream, source, 99)
    expect(picked.index).to eq(1) # first audio = default fallback
  end

  it 'select_subtitle_stream returns nil when global index has no match' do
    expect(manager.send(:select_subtitle_stream, source, 99)).to be_nil
  end
end
