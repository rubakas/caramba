require 'spec_helper'

RSpec.describe Jellyfin::Transcoding::Throttler do
  let(:fake_job) do
    Class.new do
      attr_accessor :pid, :dir, :alive
      def initialize(dir); @dir = dir; @alive = true; @pid = nil; end
      def alive?; @alive; end
    end.new(Dir.mktmpdir)
  end

  after { FileUtils.rm_rf(fake_job.dir) }

  it 'tracks last served segment' do
    t = described_class.new(fake_job, segment_length: 6, throttle_seconds: 60, interval_s: 1)
    t.note_served(0)
    t.note_served(5)
    t.note_served(3) # later notes with lower IDs don't reduce the head
    expect(t.instance_variable_get(:@last_served)).to eq(5)
  end

  it 'does not raise on tick when pid is nil' do
    t = described_class.new(fake_job, segment_length: 6, throttle_seconds: 60, interval_s: 1)
    expect { t.send(:tick) }.not_to raise_error
  end

  it 'pauses ffmpeg when the head is too far ahead of the player' do
    # Write segments 0..50 (= 300s of content) and place the served head at 0.
    51.times { |i| File.write(File.join(fake_job.dir, "#{i}.ts"), 'x') }
    pid = Process.spawn('sleep', '5')
    fake_job.pid = pid
    t = described_class.new(fake_job, segment_length: 6, throttle_seconds: 60, interval_s: 1)
    t.note_served(0)
    t.send(:tick)
    expect(t.instance_variable_get(:@paused)).to be(true)
    Process.kill('CONT', pid) rescue nil
    Process.kill('TERM', pid) rescue nil
    Process.wait(pid) rescue nil
  end
end
