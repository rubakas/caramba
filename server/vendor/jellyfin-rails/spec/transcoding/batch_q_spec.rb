require 'spec_helper'
require 'tmpdir'

RSpec.describe 'Batch Q — MaxStreamingBitrate + PingTranscodingJob' do
  describe Jellyfin::Output::AbrLadder do
    it 'drops ladder rungs whose total bitrate exceeds max_bitrate (MaxStreamingBitrate cap)' do
      ladder = described_class.build(source_height: 2160, max_bitrate: 3_000_000)
      # 480p rung is 1_400_000 + 128_000 = 1_528_000 → fits
      # 720p rung is 2_800_000 + 128_000 = 2_928_000 → fits
      # 1080p rung is 5_000_000 + 192_000 = 5_192_000 → over cap
      heights = ladder.map(&:height)
      expect(heights).to include(480, 720)
      expect(heights).not_to include(1080, 1440, 2160)
    end

    it 'falls back to the smallest rung when max_bitrate is below every rung total' do
      ladder = described_class.build(source_height: 1080, max_bitrate: 100_000)
      # All real rungs exceed 100k — we expect the fallback (lowest rung).
      expect(ladder.size).to eq(1)
    end

    it 'no-op when max_bitrate is nil' do
      ladder = described_class.build(source_height: 1080)
      expect(ladder.map(&:height)).to include(480, 720, 1080)
    end
  end

  describe Jellyfin::Transcoding::AbrOrchestrator do
    it 'passes max_bitrate from parent_job.params to AbrLadder.build' do
      tmp = Dir.mktmpdir
      parent = double(id: 'parent', dir: tmp, params: {
        max_bitrate: 2_500_000, source_height: 2160
      }, segment_length_seconds: 6)
      manager = double('mgr')
      orch = described_class.new(parent_job: parent, manager: manager)
      heights = orch.instance_variable_get(:@ladder).map(&:height)
      expect(heights.max).to be <= 720 # 720p totals 2_928_000 → drops
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe Jellyfin::Transcoding::TranscodeManager, 'ping_session (PingTranscodingJob port)' do
    let(:tmp) { Dir.mktmpdir }
    after { FileUtils.rm_rf(tmp) }

    it 'updates is_user_paused on every job matching the play_session_id' do
      mgr = described_class.new
      job1 = Jellyfin::Transcoding::TranscodingJob.new(id: 'a',
        params: { play_session_id: 'sess-1' }, root_dir: tmp)
      job2 = Jellyfin::Transcoding::TranscodingJob.new(id: 'b',
        params: { play_session_id: 'sess-1' }, root_dir: tmp)
      job3 = Jellyfin::Transcoding::TranscodingJob.new(id: 'c',
        params: { play_session_id: 'other' }, root_dir: tmp)
      mgr.instance_variable_get(:@jobs).merge!('a' => job1, 'b' => job2, 'c' => job3)
      mgr.ping_session('sess-1', is_user_paused: true)
      expect(job1.is_user_paused).to be(true)
      expect(job2.is_user_paused).to be(true)
      expect(job3.is_user_paused).to be(false) # different session — untouched
    end

    it 'is a no-op when play_session_id is blank' do
      mgr = described_class.new
      job = Jellyfin::Transcoding::TranscodingJob.new(id: 'x',
        params: { play_session_id: 'sess-1' }, root_dir: tmp)
      mgr.instance_variable_get(:@jobs)['x'] = job
      mgr.ping_session('', is_user_paused: true)
      expect(job.is_user_paused).to be(false)
    end

    it 'bumps last_ping_at even without an is_user_paused value' do
      mgr = described_class.new
      job = Jellyfin::Transcoding::TranscodingJob.new(id: 'x',
        params: { play_session_id: 'sess-1' }, root_dir: tmp)
      job.last_ping_at = 0
      mgr.instance_variable_get(:@jobs)['x'] = job
      mgr.ping_session('sess-1')
      expect(job.last_ping_at).to be > 0
    end
  end

  describe Jellyfin::Transcoding::Throttler, 'IsUserPaused integration' do
    it 'pauses ffmpeg when job.is_user_paused is set, ignoring read-ahead' do
      job = double(alive?: true, pid: Process.pid, dir: '/tmp', is_user_paused: true)
      throttler = described_class.new(job, segment_length: 6, throttle_seconds: 60)
      allow(Process).to receive(:kill).and_return(1)
      throttler.send(:tick)
      expect(Process).to have_received(:kill).with('STOP', Process.pid)
    end

    it 'resumes (read-ahead-driven) when is_user_paused is cleared' do
      # Two ticks: first sets the explicit pause, second clears it (head far
      # behind → would not auto-pause).
      job = double(alive?: true, pid: Process.pid, dir: '/tmp', is_user_paused: false)
      throttler = described_class.new(job, segment_length: 6, throttle_seconds: 60)
      throttler.instance_variable_set(:@paused, true)
      allow(Process).to receive(:kill).and_return(1)
      allow(Dir).to receive(:glob).and_return(['/tmp/0.ts'])
      throttler.instance_variable_set(:@last_served, 0)
      throttler.send(:tick)
      # head=0, last_served=0, ahead=0 → less than threshold/2 (30) → resume
      expect(Process).to have_received(:kill).with('CONT', Process.pid)
    end
  end
end

RSpec.describe 'POST /sessions/playing/progress wires paused → ping_session', type: :request do
  let(:tmp) { Dir.mktmpdir }

  before do
    Jellyfin::Transcoding::TranscodeManager.reset!
    Jellyfin::Session::Tracker.reset!
    Jellyfin::Rails.configure do |c|
      c.transcode_dir = tmp
      c.token_secret = 'q-secret'
      c.allowed_paths = []
    end
  end

  after do
    Jellyfin::Transcoding::TranscodeManager.reset!
    Jellyfin::Session::Tracker.reset!
    FileUtils.rm_rf(tmp)
  end

  it 'forwards paused=true from /progress to the TranscodeManager' do
    post '/jellyfin/sessions/playing',
         params: { session_id: 'pl-1', item_id: 'x', run_time_ticks: 100 }, as: :json

    expect(Jellyfin::Transcoding::TranscodeManager.instance).to receive(:ping_session)
      .with('pl-1', is_user_paused: true)
    post '/jellyfin/sessions/playing/progress',
         params: { session_id: 'pl-1', position_ticks: 50, paused: true }, as: :json
  end
end
