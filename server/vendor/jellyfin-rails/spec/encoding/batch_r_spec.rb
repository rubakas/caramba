require 'spec_helper'

RSpec.describe Jellyfin::Encoding::CodecInference do
  describe '.get_input_format' do
    it 'maps mkv to matroska (upstream EncodingHelper.cs:544)' do
      expect(described_class.get_input_format('mkv')).to eq('matroska')
    end

    it 'maps ts to mpegts' do
      expect(described_class.get_input_format('ts')).to eq('mpegts')
    end

    it 'returns nil for unrecognized containers (m2ts/vob/iso/etc.)' do
      %w[m2ts wmv mts vob mpg mpeg rec dvr-ms ogm divx tp rmvb rtp m4v strm iso].each do |c|
        expect(described_class.get_input_format(c)).to be_nil
      end
    end

    it 'returns nil for empty/invalid input' do
      expect(described_class.get_input_format('')).to be_nil
      expect(described_class.get_input_format(nil)).to be_nil
      expect(described_class.get_input_format('has spaces')).to be_nil
    end

    it 'returns the container itself for plain mp4, webm, flac, etc.' do
      expect(described_class.get_input_format('mp4')).to eq('mp4')
      expect(described_class.get_input_format('webm')).to eq('webm')
      expect(described_class.get_input_format('flac')).to eq('flac')
    end
  end

  describe '.infer_audio_codec' do
    it 'maps webm/ogg family → opus' do
      %w[ogg oga ogv webm webma].each do |c|
        expect(described_class.infer_audio_codec(c)).to eq('opus')
      end
    end

    it 'maps mp4 family → aac' do
      %w[m4a m4b mp4 mov mkv mka].each do |c|
        expect(described_class.infer_audio_codec(c)).to eq('aac')
      end
    end

    it 'maps ts/avi/flv → mp3' do
      %w[ts avi flv f4v swf].each do |c|
        expect(described_class.infer_audio_codec(c)).to eq('mp3')
      end
    end

    it 'defaults to aac when nothing is supplied (upstream EncodingHelper.cs:679)' do
      expect(described_class.infer_audio_codec(nil)).to eq('aac')
      expect(described_class.infer_audio_codec('')).to eq('aac')
    end
  end

  describe '.infer_video_codec' do
    it 'maps .asf → wmv' do
      expect(described_class.infer_video_codec('/foo/bar.asf')).to eq('wmv')
    end

    it 'maps .webm → vp8 (upstream TODO)' do
      expect(described_class.infer_video_codec('/foo/bar.webm')).to eq('vp8')
    end

    it 'maps .ogg/.ogv → theora' do
      expect(described_class.infer_video_codec('/foo.ogg')).to eq('theora')
      expect(described_class.infer_video_codec('/foo.ogv')).to eq('theora')
    end

    it 'maps .m3u8/.ts → h264' do
      expect(described_class.infer_video_codec('/foo.m3u8')).to eq('h264')
      expect(described_class.infer_video_codec('/foo.ts')).to eq('h264')
    end

    it 'falls back to copy for unknown extensions' do
      expect(described_class.infer_video_codec('/foo.mp4')).to eq('copy')
    end
  end

  describe '.get_video_profile_score' do
    it 'returns the canonical-order index for known H.264 profiles' do
      expect(described_class.get_video_profile_score('h264', 'Main')).to eq(3)
      expect(described_class.get_video_profile_score('h264', 'High')).to eq(4)
      expect(described_class.get_video_profile_score('h264', 'High10')).to eq(7)
    end

    it 'normalises spaces in profile names (upstream cs:729)' do
      expect(described_class.get_video_profile_score('h264', 'Constrained Baseline')).to eq(0)
    end

    it 'returns -1 for unknown profiles' do
      expect(described_class.get_video_profile_score('h264', 'NotARealProfile')).to eq(-1)
    end

    it 'returns -1 for unknown codecs' do
      expect(described_class.get_video_profile_score('vp9', 'Main')).to eq(-1)
    end

    it 'is case-insensitive' do
      expect(described_class.get_video_profile_score('h264', 'main')).to eq(3)
      expect(described_class.get_video_profile_score('HEVC', 'main10')).to eq(1)
    end
  end
end

RSpec.describe Jellyfin::Encoding::LevelNormalizer do
  describe '.normalize' do
    it 'clamps H.264 levels above 51 to 51 (upstream cs:1854)' do
      expect(described_class.normalize(video_codec: 'h264', level: 52)).to eq('51')
      expect(described_class.normalize(video_codec: 'h264', level: 62)).to eq('51')
    end

    it 'leaves H.264 levels at or below 51 alone' do
      expect(described_class.normalize(video_codec: 'h264', level: 41)).to eq('41')
      expect(described_class.normalize(video_codec: 'h264', level: 30)).to eq('30')
    end

    it 'clamps HEVC levels above 150 to 150 (upstream cs:1844)' do
      expect(described_class.normalize(video_codec: 'hevc', level: 153)).to eq('150')
      expect(described_class.normalize(video_codec: 'h265', level: 180)).to eq('150')
    end

    it 'clamps AV1 levels above 15 to 15 (upstream cs:1832)' do
      expect(described_class.normalize(video_codec: 'av1', level: 16)).to eq('15')
      expect(described_class.normalize(video_codec: 'av1', level: 19)).to eq('15')
    end

    it 'returns nil for unparseable input (upstream cs:1825)' do
      expect(described_class.normalize(video_codec: 'h264', level: 'not-a-number')).to be_nil
    end

    it 'passes through unknown codecs' do
      expect(described_class.normalize(video_codec: 'vp9', level: 41)).to eq('41')
    end
  end
end

RSpec.describe Jellyfin::Encoding::OutputFflags do
  it 'emits -fflags +genpts for HLS jobs (upstream EncodingJobInfo.GenPtsOutput → cs:7611)' do
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264')
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x', streams: [v])
    job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, output_video_codec: 'h264')
    expect(described_class.args(job)).to eq(['-fflags', '+genpts'])
  end
end
