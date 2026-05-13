require 'spec_helper'
require 'tmpdir'

RSpec.describe Jellyfin::Subtitle::ExternalPickup do
  let(:dir) { Dir.mktmpdir('jelly-subs-') }
  after { FileUtils.rm_rf(dir) }

  def touch(name)
    File.write(File.join(dir, name), '')
  end

  it 'returns [] when video file does not exist alongside any sidecar' do
    expect(described_class.discover(File.join(dir, 'movie.mkv'))).to eq([])
  end

  it 'finds plain .srt next to the video' do
    video = File.join(dir, 'show.mkv')
    File.write(video, '')
    touch('show.srt')
    side = described_class.discover(video)
    expect(side.size).to eq(1)
    expect(side.first.format).to eq('srt')
    expect(side.first.language).to be_nil
  end

  it 'parses language code from <basename>.<lang>.srt' do
    video = File.join(dir, 'show.mkv')
    File.write(video, '')
    touch('show.en.srt')
    touch('show.fr.ass')
    out = described_class.discover(video)
    en = out.find { |s| s.language == 'en' }
    fr = out.find { |s| s.language == 'fr' }
    expect(en.format).to eq('srt')
    expect(fr.format).to eq('ass')
  end

  it 'marks forced tracks' do
    video = File.join(dir, 'movie.mkv')
    File.write(video, '')
    touch('movie.en.forced.srt')
    out = described_class.discover(video)
    expect(out.first.forced).to be(true)
    expect(out.first.language).to eq('en')
  end

  it 'marks SDH / hearing-impaired tracks' do
    video = File.join(dir, 'movie.mkv')
    File.write(video, '')
    touch('movie.en.sdh.srt')
    out = described_class.discover(video)
    expect(out.first.hearing_impaired).to be(true)
  end

  it 'ignores foreign files that happen to share an extension' do
    video = File.join(dir, 'movie.mkv')
    File.write(video, '')
    touch('other-thing.srt')
    expect(described_class.discover(video)).to be_empty
  end
end
