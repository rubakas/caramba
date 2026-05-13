require 'spec_helper'
require 'tmpdir'

RSpec.describe Jellyfin::MediaEncoder::CodecCapabilities do
  let(:caps) do
    Class.new do
      def supports_encoder?(name); %w[libopus libmp3lame aac flac libfdk_aac].include?(name); end
    end.new
  end

  describe '.can_encode_to_audio_codec? (upstream MediaEncoder.cs:394)' do
    it 'normalises opus → libopus before checking' do
      expect(described_class.can_encode_to_audio_codec?('opus', capabilities: caps)).to be(true)
    end

    it 'normalises mp3 → libmp3lame' do
      expect(described_class.can_encode_to_audio_codec?('mp3', capabilities: caps)).to be(true)
    end

    it 'passes through other codec names verbatim' do
      expect(described_class.can_encode_to_audio_codec?('aac', capabilities: caps)).to be(true)
      expect(described_class.can_encode_to_audio_codec?('flac', capabilities: caps)).to be(true)
    end

    it 'returns false for codecs the encoder list lacks' do
      expect(described_class.can_encode_to_audio_codec?('ac3', capabilities: caps)).to be(false)
    end

    it 'returns false for nil / empty input' do
      expect(described_class.can_encode_to_audio_codec?(nil, capabilities: caps)).to be(false)
      expect(described_class.can_encode_to_audio_codec?('', capabilities: caps)).to be(false)
    end
  end

  describe '.can_encode_to_subtitle_codec? (upstream cs:408 — TODO returning true)' do
    it 'returns true unconditionally to match upstream' do
      expect(described_class.can_encode_to_subtitle_codec?('subrip')).to be(true)
      expect(described_class.can_encode_to_subtitle_codec?(nil)).to be(true)
    end
  end
end

RSpec.describe Jellyfin::Images::Converter do
  let(:tmp) { Dir.mktmpdir }
  after { FileUtils.rm_rf(tmp) }

  let(:converter) { described_class.new(ffmpeg_path: ENV['TEST_FFMPEG_PATH'] || '/usr/local/bin/ffmpeg') }

  it 'rejects unsupported input extensions' do
    expect {
      converter.convert(input_path: '/dev/null.exr', output_path: '/tmp/x.jpg')
    }.to raise_error(described_class::ConversionFailed)
  end

  it 'rejects unsupported output extensions' do
    File.write(File.join(tmp, 'in.jpg'), 'fake')
    expect {
      converter.convert(input_path: File.join(tmp, 'in.jpg'), output_path: File.join(tmp, 'out.exr'))
    }.to raise_error(described_class::ConversionFailed, /unsupported output format/)
  end

  it 'raises ConversionFailed when ffmpeg cant decode the input' do
    ffmpeg = ENV['TEST_FFMPEG_PATH'] || '/Applications/Jellyfin.app/Contents/MacOS/ffmpeg'
    skip 'ffmpeg not present' unless File.executable?(ffmpeg)
    converter = described_class.new(ffmpeg_path: ffmpeg)
    File.write(File.join(tmp, 'in.jpg'), 'not a real jpeg')
    expect {
      converter.convert(input_path: File.join(tmp, 'in.jpg'), output_path: File.join(tmp, 'out.png'))
    }.to raise_error(described_class::ConversionFailed)
  end
end

RSpec.describe Jellyfin::Subtitle::ExternalPickup do
  describe '.get_subtitle_file_path (upstream SubtitleEncoder.cs:1030)' do
    it 'returns the external_path verbatim when the stream is sidecar' do
      tmp = Dir.mktmpdir
      v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264')
      s = Jellyfin::Probing::MediaStream.new(index: 2, type: :subtitle, codec: 'subrip',
        external_path: '/sidecars/movie.eng.srt')
      src = Jellyfin::Probing::MediaSourceInfo.new(path: '/movies/movie.mkv', streams: [v, s])
      out = described_class.get_subtitle_file_path(stream: s, media_source: src, cache_root: tmp)
      expect(out).to eq('/sidecars/movie.eng.srt')
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it 'returns a digest-based cache path for embedded streams' do
      tmp = Dir.mktmpdir
      v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264')
      s = Jellyfin::Probing::MediaStream.new(index: 2, type: :subtitle, codec: 'subrip')
      src = Jellyfin::Probing::MediaSourceInfo.new(path: '/movies/movie.mkv', streams: [v, s])
      out = described_class.get_subtitle_file_path(stream: s, media_source: src, cache_root: tmp)
      expect(out).to start_with(File.join(tmp, 'subs'))
      expect(out).to end_with('.vtt')
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end
end

RSpec.describe Jellyfin::Encoding::Hwaccel::VaapiDetect do
  before { described_class.reset! }

  it 'amd? falls back to false when vainfo is not available' do
    allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)
    described_class.reset!
    expect(described_class.amd?).to be(false)
  end

  it 'detects iHD when vainfo reports it (upstream MediaEncoder.cs:155)' do
    fake_output = "vainfo: VA-API version: 1.20.0\nDriver version: Intel iHD driver for Intel(R) Gen Graphics - 24.1.0\n"
    allow(Open3).to receive(:capture3).and_return([fake_output, '', instance_double(Process::Status, success?: true)])
    described_class.reset!
    expect(described_class.intel_ihd?).to be(true)
  end

  it 'detects i965 when vainfo reports it' do
    fake = "Driver version: Intel i965 driver for Intel(R) HD Graphics - 2.4.1\n"
    allow(Open3).to receive(:capture3).and_return([fake, '', instance_double(Process::Status, success?: true)])
    described_class.reset!
    expect(described_class.intel_i965?).to be(true)
  end

  it 'detects amdgpu / radeonsi' do
    fake = "Driver version: amdgpu Mesa 23.2.1 for AMD Radeon\n"
    allow(Open3).to receive(:capture3).and_return([fake, '', instance_double(Process::Status, success?: true)])
    described_class.reset!
    expect(described_class.amd?).to be(true)
  end
end

RSpec.describe Jellyfin::Subtitle::BulkExtractor do
  let(:tmp) { Dir.mktmpdir }
  after { FileUtils.rm_rf(tmp) }

  it 'returns [] for sources with no text subtitle streams' do
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264')
    a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac')
    src = Jellyfin::Probing::MediaSourceInfo.new(path: File.join(tmp, 'fake.mkv'), streams: [v, a])
    File.write(src.path, 'fake')
    extractor = described_class.new(ffmpeg_path: '/usr/bin/true', cache_root: tmp)
    expect(extractor.extract_all(src)).to eq([])
  end

  it 'builds one ffmpeg invocation with per-stream -map + -c:s args' do
    File.write(File.join(tmp, 'movie.mkv'), 'fake')
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264')
    s1 = Jellyfin::Probing::MediaStream.new(index: 2, type: :subtitle, codec: 'subrip', language: 'eng')
    s2 = Jellyfin::Probing::MediaStream.new(index: 3, type: :subtitle, codec: 'ass', language: 'jpn')
    src = Jellyfin::Probing::MediaSourceInfo.new(path: File.join(tmp, 'movie.mkv'), streams: [v, s1, s2])

    captured_args = nil
    allow(Open3).to receive(:capture3) do |*args|
      captured_args = args
      [+'', +'', instance_double(Process::Status, success?: true)]
    end
    extractor = described_class.new(ffmpeg_path: '/usr/bin/true', cache_root: tmp)
    extractor.extract_all(src)
    expect(captured_args.flatten).to include('-map', '0:2')
    expect(captured_args.flatten).to include('-map', '0:3')
    expect(captured_args.flatten).to include('-c:s', 'srt')
  end
end

RSpec.describe Jellyfin::Probing::Stereo3d do
  it 'detects side-by-side from filename pattern' do
    expect(described_class.detect_from_filename('/movies/Avatar.SBS.mkv')).to eq(:sbs)
    expect(described_class.detect_from_filename('/movies/film.side_by_side.mkv')).to eq(:sbs)
  end

  it 'detects half-side-by-side specifically (more specific than plain SBS)' do
    expect(described_class.detect_from_filename('/movies/Avatar.HSBS.mkv')).to eq(:hsbs)
  end

  it 'detects over-under from filename' do
    expect(described_class.detect_from_filename('/movies/film.OU.mkv')).to eq(:ou)
    expect(described_class.detect_from_filename('/movies/film.top-bottom.mkv')).to eq(:ou)
  end

  it 'returns nil for non-3D filenames' do
    expect(described_class.detect_from_filename('/movies/normal-movie.mkv')).to be_nil
  end

  it 'detects side-by-side from ffprobe Stereo 3D side_data' do
    side = [{ 'side_data_type' => 'Stereo 3D', 'type' => 'side_by_side' }]
    expect(described_class.detect_from_side_data(side)).to eq(:sbs)
  end

  it 'side-data wins over filename when both are present' do
    side = [{ 'side_data_type' => 'Stereo 3D', 'type' => 'top_bottom' }]
    out = described_class.detect(side, '/movies/Avatar.SBS.mkv')
    expect(out).to eq(:ou)
  end
end

RSpec.describe Jellyfin::Probing::DvdBluRay do
  let(:tmp) { Dir.mktmpdir }
  after { FileUtils.rm_rf(tmp) }

  describe '.primary_vob_files (upstream MediaEncoder.cs:1222)' do
    it 'returns [] when the path has no VOB files' do
      expect(described_class.primary_vob_files(tmp)).to eq([])
    end

    it 'groups VTS_NN_M.VOB files by title number, omitting menus and intros' do
      FileUtils.mkdir_p(File.join(tmp, 'VIDEO_TS'))
      ['VIDEO_TS.VOB', 'VTS_01_0.VOB', 'VTS_01_1.VOB', 'VTS_01_2.VOB',
       'VTS_02_0.VOB', 'VTS_02_1.VOB'].each do |f|
        File.write(File.join(tmp, 'VIDEO_TS', f), 'x' * 1_000_000_000) # 1GB each
      end
      files = described_class.primary_vob_files(tmp, title_number: 1)
      expect(files.map { |p| File.basename(p) }).to eq(['VTS_01_1.VOB', 'VTS_01_2.VOB'])
    end

    it 'picks the largest title when no title_number is supplied' do
      FileUtils.mkdir_p(File.join(tmp, 'VIDEO_TS'))
      File.write(File.join(tmp, 'VIDEO_TS', 'VTS_01_1.VOB'), 'x' * 100_000_000)        # 100MB
      File.write(File.join(tmp, 'VIDEO_TS', 'VTS_02_1.VOB'), 'x' * 1_000_000_000)      # 1GB
      files = described_class.primary_vob_files(tmp)
      expect(files.first).to end_with('VTS_02_1.VOB')
    end
  end

  describe '.primary_m2ts_files (Blu-ray equivalent)' do
    it 'returns the M2TS files under BDMV/STREAM/ matching the title number' do
      FileUtils.mkdir_p(File.join(tmp, 'BDMV', 'STREAM'))
      File.write(File.join(tmp, 'BDMV', 'STREAM', '00001.m2ts'), 'x')
      File.write(File.join(tmp, 'BDMV', 'STREAM', '00800.m2ts'), 'x')
      out = described_class.primary_m2ts_files(tmp, title_number: 800)
      expect(out.first).to end_with('00800.m2ts')
    end

    it 'picks the largest .m2ts as the main feature when title is unspecified' do
      FileUtils.mkdir_p(File.join(tmp, 'BDMV', 'STREAM'))
      # Use sparse files (truncate) to simulate the large-file sizes without
      # actually allocating gigabytes of disk.
      File.open(File.join(tmp, 'BDMV', 'STREAM', '00001.m2ts'), 'wb') { |f| f.truncate(50_000_000) }
      File.open(File.join(tmp, 'BDMV', 'STREAM', '00800.m2ts'), 'wb') { |f| f.truncate(5_000_000_000) }
      out = described_class.primary_m2ts_files(tmp)
      expect(out.first).to end_with('00800.m2ts')
    end
  end
end

RSpec.describe Jellyfin::Probing::ChaptersExtended do
  it 'normalises ffprobe chapter blobs into the MediaSourceInfo shape' do
    raw = [{ 'id' => 0, 'start_time' => '0.0', 'end_time' => '90.0', 'tags' => { 'title' => 'Opening' } },
           { 'id' => 1, 'start_time' => '90.0', 'end_time' => '180.0', 'tags' => { 'title' => 'Chapter 2' } }]
    out = described_class.normalize(raw)
    expect(out.size).to eq(2)
    expect(out.first[:title]).to eq('Opening')
    expect(out.first[:start_time]).to eq(0.0)
  end

  it 'drops phantom chapters past run_time_seconds' do
    raw = [{ 'id' => 0, 'start_time' => '0.0', 'end_time' => '60.0' },
           { 'id' => 1, 'start_time' => '60.0', 'end_time' => '120.0' },
           { 'id' => 2, 'start_time' => '99999.0', 'end_time' => '99999.5' }]
    out = described_class.normalize(raw, run_time_seconds: 120.0)
    expect(out.size).to eq(2)
  end

  it 'synthesises uniform chapters when ffprobe reports none' do
    out = described_class.synthesize_uniform(run_time_seconds: 600.0, count: 5)
    expect(out.size).to eq(5)
    expect(out.first[:start_time]).to eq(0.0)
    expect(out.last[:end_time]).to eq(600.0)
    expect(out.first[:title]).to eq('Chapter 1')
  end
end

RSpec.describe Jellyfin::Encoding::InputArgument, 'multi-file overload (upstream MediaEncoder.cs:471)' do
  it 'emits concat:fileA|fileB when EncodingOptions#input_files is set' do
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264')
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/dvd/VTS_01_1.VOB', streams: [v])
    opts = Jellyfin::Encoding::EncodingOptions.new
    opts.define_singleton_method(:input_files) { ['/dvd/VTS_01_1.VOB', '/dvd/VTS_01_2.VOB'] }
    job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, options: opts, output_video_codec: 'h264')
    args = described_class.call(job: job)
    expect(args).to include('-i', 'concat:/dvd/VTS_01_1.VOB|/dvd/VTS_01_2.VOB')
  end
end
