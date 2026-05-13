require 'spec_helper'
require 'tmpdir'

RSpec.describe Jellyfin::Subtitle::AttachmentExtractor do
  let(:cache) { Dir.mktmpdir('jelly-fonts-') }
  let(:source) { File.join(cache, 'movie.mkv') }
  after { FileUtils.rm_rf(cache) }

  it 'returns [] for a non-existent source path' do
    extractor = described_class.new(ffmpeg_path: '/usr/bin/false', cache_root: cache)
    expect(extractor.extract('/no/such/file.mkv')).to eq([])
  end

  it 'caches by mtime+size — second call does not re-run ffmpeg' do
    File.write(source, 'fake mkv')
    extractor = described_class.new(ffmpeg_path: '/usr/bin/true', cache_root: cache)
    allow(extractor).to receive(:run_extract).and_return([
      described_class::Attachment.new(filename: 'OpenSans.ttf', path: '/tmp/OpenSans.ttf', mimetype: 'font/ttf')
    ])
    extractor.extract(source)
    expect(extractor).to have_received(:run_extract).once
    extractor.extract(source) # should hit cache
    expect(extractor).to have_received(:run_extract).once
  end

  it 'invalidates the cache when the source file changes' do
    File.write(source, 'old')
    extractor = described_class.new(ffmpeg_path: '/usr/bin/true', cache_root: cache)
    allow(extractor).to receive(:run_extract).and_return([])
    extractor.extract(source)
    sleep 1 # mtime resolution is per-second on most filesystems
    File.write(source, 'new content larger')
    extractor.extract(source)
    expect(extractor).to have_received(:run_extract).twice
  end

  it 'filters out non-font attachments' do
    File.write(source, 'fake mkv')
    extractor = described_class.new(ffmpeg_path: '/usr/bin/true', cache_root: cache)
    allow(extractor).to receive(:run_extract).and_wrap_original do |_orig, _src, _dir|
      [
        described_class::Attachment.new(filename: 'cover.jpg', path: '/tmp/cover.jpg', mimetype: 'image/jpeg'),
        described_class::Attachment.new(filename: 'Arial.ttf', path: '/tmp/Arial.ttf', mimetype: 'font/ttf')
      ].select { |a| extractor.send(:font?, a) }
    end
    out = extractor.extract(source)
    expect(out.map(&:filename)).to eq(['Arial.ttf'])
  end
end
