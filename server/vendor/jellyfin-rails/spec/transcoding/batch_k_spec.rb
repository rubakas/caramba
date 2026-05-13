require 'spec_helper'
require 'tmpdir'

RSpec.describe 'Batch K — Transcoding manager production features' do
  describe Jellyfin::Transcoding::ProgressReader do
    let(:tmp) { Dir.mktmpdir('progress-') }
    let(:pipe) { File.join(tmp, 'progress.txt') }
    after { FileUtils.rm_rf(tmp) }

    it 'parses ffmpeg progress key=value pairs out of the pipe' do
      File.write(pipe, '')
      reader = described_class.new(pipe).start
      File.open(pipe, 'a') do |f|
        f.puts 'frame=120'
        f.puts 'fps=24.0'
        f.puts 'bitrate=2500.0kbits/s'
        f.puts 'total_size=4500000'
        f.puts 'out_time_ms=5000000'
        f.puts 'dup_frames=0'
        f.puts 'drop_frames=2'
        f.puts 'speed=1.02x'
        f.puts 'progress=continue'
      end
      sleep 0.3
      snap = reader.snapshot
      reader.stop
      expect(snap.frame).to eq(120)
      expect(snap.fps).to eq(24.0)
      expect(snap.speed).to eq('1.02x')
      expect(snap.status).to eq('continue')
      expect(snap.out_time_seconds).to eq(5.0)
    end

    it 'emits -progress + -nostats args for the spawn line' do
      reader = described_class.new('/x/progress.txt')
      expect(reader.args_for_ffmpeg).to eq(['-progress', '/x/progress.txt', '-nostats'])
    end
  end

  describe Jellyfin::Transcoding::ConcurrencyLimiter do
    it 'unlimited when max=0' do
      lim = described_class.new(max_concurrent: 0)
      expect(lim).to be_unlimited
      lim.acquire('a'); lim.acquire('b'); lim.acquire('c')
      expect(lim.in_flight).to eq(0) # unlimited mode doesn't track
    end

    it 'enforces the cap and raises after timeout' do
      lim = described_class.new(max_concurrent: 2)
      lim.acquire('a')
      lim.acquire('b')
      expect {
        lim.acquire('c', timeout: 0.05)
      }.to raise_error(described_class::CapExceeded)
    end

    it 'lets a new acquirer through once a slot frees' do
      lim = described_class.new(max_concurrent: 1)
      lim.acquire('a')
      th = Thread.new { lim.acquire('b', timeout: 1) }
      sleep 0.05
      lim.release('a')
      th.join(1)
      expect(lim.in_flight).to eq(1)
      expect(lim.held?('b')).to be(true)
    end

    it 're-entrant: same id reacquiring is a no-op' do
      lim = described_class.new(max_concurrent: 1)
      lim.acquire('a')
      expect { lim.acquire('a', timeout: 0.05) }.not_to raise_error
    end
  end

  describe Jellyfin::Transcoding::CancellationToken do
    it 'starts not cancelled' do
      expect(described_class.new).not_to be_cancelled
    end

    it 'fires listeners on cancel' do
      tok = described_class.new
      fired = false
      tok.on_cancel { fired = true }
      tok.cancel!
      expect(fired).to be(true)
      expect(tok).to be_cancelled
    end

    it 'is idempotent — cancel! twice fires listeners once' do
      tok = described_class.new
      count = 0
      tok.on_cancel { count += 1 }
      tok.cancel!
      tok.cancel!
      expect(count).to eq(1)
    end

    it 'fires the listener immediately if registered after cancel' do
      tok = described_class.new
      tok.cancel!
      fired = false
      tok.on_cancel { fired = true }
      expect(fired).to be(true)
    end
  end

  describe Jellyfin::Transcoding::LiveStreamRegistry do
    before { described_class.reset! }

    it 'reference-counts consumers and runs close when last consumer drops' do
      reg = described_class.instance
      closed = false
      reg.register('hdhr-1', close: -> { closed = true })
      reg.register('hdhr-1', close: -> { closed = true })
      expect(reg.refcount('hdhr-1')).to eq(2)
      reg.release('hdhr-1')
      expect(closed).to be(false)
      reg.release('hdhr-1')
      expect(closed).to be(true)
      expect(reg).not_to be_open('hdhr-1')
    end
  end

  describe Jellyfin::Transcoding::AbrOrchestrator do
    it 'writes a master playlist referencing each variant subdir' do
      tmp = Dir.mktmpdir
      job = double(id: 'parent', dir: tmp,
                   params: { video_codec: 'h264', audio_codec: 'aac',
                             source_height: 1080, source_bitrate: 5_000_000 },
                   segment_length_seconds: 6)
      manager = double('manager')
      orch = described_class.new(parent_job: job, manager: manager,
                                  ladder: [
                                    Jellyfin::Output::AbrLadder::Variant.new(
                                      name: '720p', height: 720, width: 1280,
                                      video_bitrate: 2_800_000, audio_bitrate: 128_000
                                    ),
                                    Jellyfin::Output::AbrLadder::Variant.new(
                                      name: '1080p', height: 1080, width: 1920,
                                      video_bitrate: 5_000_000, audio_bitrate: 192_000
                                    )
                                  ])
      child_720 = double(id: 'parent-720p')
      child_1080 = double(id: 'parent-1080p')
      expect(manager).to receive(:ensure_started)
        .with(id: 'parent-720p', params: hash_including(max_height: 720)).and_return(child_720)
      expect(manager).to receive(:ensure_started)
        .with(id: 'parent-1080p', params: hash_including(max_height: 1080)).and_return(child_1080)
      orch.start!
      master = File.read(File.join(tmp, 'master.m3u8'))
      expect(master).to include('#EXTM3U')
      expect(master).to include('BANDWIDTH=2928000') # 2_800_000 + 128_000
      expect(master).to include('BANDWIDTH=5192000')
      expect(master).to include('720p/master.m3u8')
      expect(master).to include('RESOLUTION=1920x1080')
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe Jellyfin::Transcoding::TranscodingJob do
    let(:tmp) { Dir.mktmpdir('job-') }
    after { FileUtils.rm_rf(tmp) }

    it 'exposes a cancellation token' do
      job = described_class.new(id: 'x', params: {}, root_dir: tmp)
      expect(job.cancellation_token).to be_a(Jellyfin::Transcoding::CancellationToken)
    end

    it 'fires cancellation on kill!' do
      job = described_class.new(id: 'x', params: {}, root_dir: tmp)
      job.kill!
      expect(job.cancellation_token).to be_cancelled
    end

    it 'progress_snapshot returns {} when no reader is wired' do
      job = described_class.new(id: 'x', params: {}, root_dir: tmp)
      expect(job.progress_snapshot).to eq({})
    end
  end
end
