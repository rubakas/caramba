require 'spec_helper'
require 'tmpdir'

RSpec.describe Jellyfin::Transcoding::SegmentCleaner do
  let(:tmp_root) { Dir.mktmpdir }
  after { FileUtils.rm_rf(tmp_root) }

  let(:job) do
    Struct.new(:dir).new(tmp_root)
  end

  it 'deletes only the segments beyond the keep window' do
    30.times { |i| File.write(File.join(tmp_root, "#{i}.ts"), 'data') }
    described_class.new(job, keep_segments: 10).sweep

    remaining = Dir.children(tmp_root).map { |f| File.basename(f, '.ts').to_i }.sort
    expect(remaining).to eq((20..29).to_a)
  end

  it 'is a no-op when segment count is within the window' do
    5.times { |i| File.write(File.join(tmp_root, "#{i}.ts"), 'data') }
    described_class.new(job, keep_segments: 10).sweep
    expect(Dir.children(tmp_root).size).to eq(5)
  end
end
