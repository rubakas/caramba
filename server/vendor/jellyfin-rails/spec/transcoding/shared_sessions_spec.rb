require 'spec_helper'
require 'tmpdir'

RSpec.describe 'TranscodeManager shared sessions + restart-at-segment' do
  let(:fixture)  { File.join(FIXTURE_PATH, 'sample.mp4') }
  let(:tmp_root) { Dir.mktmpdir('jelly-shared-') }

  before do
    skip 'fixture missing' unless File.exist?(fixture)
    ffmpeg = ENV.fetch('TEST_FFMPEG_PATH', '/Applications/Jellyfin.app/Contents/MacOS/ffmpeg')
    skip 'ffmpeg not present' unless File.executable?(ffmpeg)

    Jellyfin::Transcoding::TranscodeManager.reset!
    Jellyfin::Rails.configure do |c|
      c.ffmpeg_path = ffmpeg
      c.transcode_dir = tmp_root
      c.token_secret = 'test-secret'
      c.idle_timeout = 60
      c.segment_length = 1
    end
  end

  after do
    Jellyfin::Transcoding::TranscodeManager.reset!
    FileUtils.rm_rf(tmp_root)
  end

  let(:manager) { Jellyfin::Transcoding::TranscodeManager.instance }

  it 'increments ref_count when multiple clients attach to the same id' do
    j1 = manager.ensure_started(id: 'shared', params: { path: fixture, segment_length: 1 })
    j2 = manager.ensure_started(id: 'shared', params: { path: fixture, segment_length: 1 })
    expect(j2).to equal(j1)
    expect(j1.ref_count).to eq(2)
    manager.detach!('shared')
    expect(j1.ref_count).to eq(1)
    manager.detach!('shared')
    expect(j1.ref_count).to eq(0)
    manager.stop!('shared')
  end

  # Updated contract (2026-05-14): reap_idle now fires regardless of
  # ref_count, matching upstream's PingTimer behaviour
  # (TranscodeManager.cs:174). ref_count only counts `attach!` calls and
  # is never decremented on HTTP-level client disconnect — so it grew
  # unbounded with every segment request and the previous "keep alive
  # while ref_count > 0" rule turned every closed playback into an
  # orphan ffmpeg. Clients that need to keep a job warm beyond
  # idle_timeout must send segment/playlist requests to ping it.
  it 'reaps an idle job even when ref_count is still positive (matches upstream PingTimer)' do
    job = manager.ensure_started(id: 'sticky', params: { path: fixture, segment_length: 1 })
    # ensure_started already auto-attached; bump it further to make the
    # point that the count being > 1 does not save the job.
    job.attach!; job.attach!
    job.last_ping_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 9999
    manager.reap_idle
    expect(manager.find('sticky')).to be_nil
    expect(job.alive?).to be(false)
  end

  it 'restarts ffmpeg with a fresh log + new -ss when client requests a far-ahead segment' do
    job = manager.ensure_started(id: 'seek-test', params: { path: fixture, segment_length: 1 })
    initial_log = job.stderr_path

    # Force a seek request well past the restart threshold.
    manager.request_segment('seek-test', 25)

    expect(job.start_segment).to eq(25)
    expect(job.restart_count).to be >= 1
    expect(job.stderr_path).not_to eq(initial_log)
    expect(File.basename(job.stderr_path)).to match(/ffmpeg\.\d+\.log/)

    manager.stop!('seek-test')
  end

  it 'leaves the job alone when the requested segment matches the current start_segment' do
    job = manager.ensure_started(id: 'no-seek', params: { path: fixture, segment_length: 1 })
    pid_before = job.pid
    manager.request_segment('no-seek', 0)
    expect(job.start_segment).to eq(0)
    expect(job.pid).to eq(pid_before)
    manager.stop!('no-seek')
  end

  it 'restarts on first segment request when it does not match the start_segment' do
    # Matches upstream's GetDynamicSegment behaviour: when
    # `currentTranscodingIndex is null` (no segment produced yet), the
    # next segment request determines where ffmpeg is started/restarted.
    # Without this, ffmpeg keeps emitting `0.ts, 1.ts, …` while the
    # client (via the player's seekOnPlaybackStart) requests the segment
    # that maps to its currentTime — a mismatch that wedges Safari on a
    # "waiting" state until the player gives up (the user's "movies
    # don't play in Safari" report).
    job = manager.ensure_started(id: 'mismatch', params: { path: fixture, segment_length: 1 })
    initial_log = job.stderr_path
    manager.request_segment('mismatch', 3)
    expect(job.start_segment).to eq(3)
    expect(job.restart_count).to be >= 1
    expect(job.stderr_path).not_to eq(initial_log)
    manager.stop!('mismatch')
  end
end

RSpec.describe Jellyfin::Transcoding::TranscodingJob do
  let(:tmp_root) { Dir.mktmpdir('jelly-job-') }
  after { FileUtils.rm_rf(tmp_root) }

  it 'attach!/detach! refcount never goes negative' do
    job = described_class.new(id: 'x', params: {}, root_dir: tmp_root)
    expect(job.ref_count).to eq(0)
    job.attach!; job.attach!
    expect(job.ref_count).to eq(2)
    job.detach!; job.detach!; job.detach!
    expect(job.ref_count).to eq(0)
  end

  it 'rotate_log! gives each restart its own log file path' do
    job = described_class.new(id: 'y', params: {}, root_dir: tmp_root)
    job.restart_count = 1
    job.rotate_log!
    expect(File.basename(job.stderr_path)).to eq('ffmpeg.1.log')
    job.restart_count = 2
    job.rotate_log!
    expect(File.basename(job.stderr_path)).to eq('ffmpeg.2.log')
  end

  it 'seek_seconds_for multiplies segment count by segment length' do
    job = described_class.new(id: 'z', params: { segment_length: 6 }, root_dir: tmp_root)
    expect(job.seek_seconds_for(10)).to eq(60)
  end
end
