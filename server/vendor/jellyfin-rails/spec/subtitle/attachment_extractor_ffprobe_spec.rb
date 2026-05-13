require 'spec_helper'
require 'tmpdir'
require 'json'

RSpec.describe Jellyfin::Subtitle::AttachmentExtractor do
  let(:tmp) { Dir.mktmpdir('att-') }
  let(:source) { File.join(tmp, 'movie.mkv') }
  after { FileUtils.rm_rf(tmp) }

  it 'parses attachment streams from ffprobe JSON instead of stderr scraping' do
    File.write(source, 'fake mkv')
    extractor = described_class.new(
      ffmpeg_path: '/usr/local/bin/ffmpeg',
      ffprobe_path: '/usr/local/bin/ffprobe',
      cache_root: tmp
    )
    fake_json = JSON.dump('streams' => [
      { 'index' => 0, 'codec_type' => 'video' },
      { 'index' => 2, 'codec_type' => 'attachment', 'codec_name' => 'ttf',
        'tags' => { 'filename' => 'OpenSans.ttf', 'mimetype' => 'application/x-truetype-font' } },
      { 'index' => 3, 'codec_type' => 'attachment', 'codec_name' => 'ttf',
        'tags' => { 'filename' => 'Arial.ttf', 'mimetype' => 'font/ttf' } }
    ])
    allow(Open3).to receive(:capture3)
      .with('/usr/local/bin/ffprobe', '-v', 'error', '-show_streams', '-of', 'json', source)
      .and_return([fake_json, '', instance_double(Process::Status, success?: true)])

    out = extractor.send(:list_attachments, source)
    expect(out.map { |a| a[:filename] }).to eq(['OpenSans.ttf', 'Arial.ttf'])
    expect(out.first[:mimetype]).to eq('application/x-truetype-font')
  end

  it 'returns [] when ffprobe fails' do
    File.write(source, 'fake')
    extractor = described_class.new(ffmpeg_path: '/usr/bin/ffmpeg',
                                    ffprobe_path: '/usr/bin/ffprobe', cache_root: tmp)
    allow(Open3).to receive(:capture3).and_return(['', 'err', instance_double(Process::Status, success?: false)])
    expect(extractor.send(:list_attachments, source)).to eq([])
  end

  it 'tolerates ffprobe returning non-JSON garbage' do
    File.write(source, 'fake')
    extractor = described_class.new(ffmpeg_path: '/usr/bin/ffmpeg',
                                    ffprobe_path: '/usr/bin/ffprobe', cache_root: tmp)
    allow(Open3).to receive(:capture3).and_return(['not json', '', instance_double(Process::Status, success?: true)])
    expect(extractor.send(:list_attachments, source)).to eq([])
  end
end
