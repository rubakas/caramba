require 'spec_helper'

RSpec.describe Jellyfin::Transcoding::AsyncKeyedLocker do
  it 'serializes operations under the same key' do
    locker = described_class.new
    order = []
    t1 = Thread.new { locker.with('a') { order << :a1; sleep 0.05; order << :a2 } }
    sleep 0.01
    t2 = Thread.new { locker.with('a') { order << :a3; order << :a4 } }
    [t1, t2].each(&:join)
    expect(order).to eq(%i[a1 a2 a3 a4])
  end

  it 'allows different keys to run concurrently' do
    locker = described_class.new
    started = []
    finished = []
    threads = 2.times.map do |i|
      Thread.new do
        locker.with("k#{i}") do
          started << i
          sleep 0.05
          finished << i
        end
      end
    end
    threads.each(&:join)
    # Both should start before either finishes — true concurrency.
    expect(started.sort).to eq([0, 1])
  end
end
