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
end
