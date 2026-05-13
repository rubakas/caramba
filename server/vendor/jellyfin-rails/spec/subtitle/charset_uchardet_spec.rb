require 'spec_helper'
require 'tmpdir'

RSpec.describe Jellyfin::Subtitle::Charset do
  let(:tmp) { Dir.mktmpdir('charset-') }
  let(:srt) { File.join(tmp, 'sub.srt') }
  before { Jellyfin::Subtitle::Charset.reset_uchardet_cache! }
  after  { FileUtils.rm_rf(tmp) }

  it 'consults uchardet for path input and trusts its answer when not "unknown"' do
    File.write(srt, "1\n00:00:01,000 --> 00:00:02,000\nhello\n")
    allow(Open3).to receive(:capture3).with('uchardet', srt)
      .and_return(["UTF-8\n", '', instance_double(Process::Status, success?: true)])
    expect(described_class.detect(srt)).to eq('UTF-8')
  end

  it 'falls back to the heuristic when uchardet says "unknown"' do
    File.binwrite(srt, ((0xC0..0xFF).to_a.pack('C*') * 10))
    allow(Open3).to receive(:capture3).with('uchardet', srt)
      .and_return(["unknown\n", '', instance_double(Process::Status, success?: true)])
    expect(described_class.detect(srt)).to eq('WINDOWS-1251')
  end

  it 'falls back to the heuristic when uchardet binary is missing' do
    File.binwrite(srt, "plain ascii subtitle line")
    allow(Open3).to receive(:capture3).with('uchardet', srt).and_raise(Errno::ENOENT)
    expect(described_class.detect(srt)).to eq('UTF-8')
  end

  it 'memoizes the missing-binary state so subsequent calls do not retry' do
    File.binwrite(srt, "another")
    allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)
    described_class.detect(srt)
    expect(Open3).to have_received(:capture3).once
    described_class.detect(srt) # should not re-spawn
    expect(Open3).to have_received(:capture3).once
  end
end
