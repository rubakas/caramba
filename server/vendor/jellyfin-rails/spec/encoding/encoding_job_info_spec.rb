require 'spec_helper'
require 'jellyfin/encoding/encoding_job_info'

RSpec.describe Jellyfin::Encoding::EncodingJobInfo do
  def mk_video(codec: 'hevc')
    Jellyfin::Probing::MediaStream.new(
      index: 0, type: :video, codec: codec, width: 1920, height: 1080
    )
  end

  def mk_audio(codec: 'ac3')
    Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: codec, channels: 6)
  end

  def mk_source(video_codec: 'hevc', audio_codec: 'ac3')
    Jellyfin::Probing::MediaSourceInfo.new(
      id: 'x', path: '/x.mkv',
      streams: [mk_video(codec: video_codec), mk_audio(codec: audio_codec)]
    )
  end

  describe '#actual_output_video_codec' do
    # Mirrors upstream EncodingJobInfo.cs:420. The CODECS attribute in
    # the HLS master playlist must reflect what ffmpeg actually emits,
    # not the source — otherwise browsers reject the stream with
    # MEDIA_ERR_SRC_NOT_SUPPORTED when the source is HEVC but the
    # output is H.264.
    it 'returns the target codec when transcoding (libx264 → h264)' do
      info = described_class.new(media_source: mk_source, output_video_codec: 'libx264')
      expect(info.actual_output_video_codec).to eq('h264')
    end

    it 'returns the source codec when remuxing (output = copy)' do
      info = described_class.new(media_source: mk_source(video_codec: 'h264'), output_video_codec: 'copy')
      expect(info.actual_output_video_codec).to eq('h264')
    end

    it 'normalises hardware encoders to the codec family' do
      info = described_class.new(media_source: mk_source, output_video_codec: 'h264_videotoolbox')
      expect(info.actual_output_video_codec).to eq('h264')
    end

    it 'returns nil when there is no video stream' do
      src = Jellyfin::Probing::MediaSourceInfo.new(id: 'a', path: '/x.mp3', streams: [mk_audio])
      info = described_class.new(media_source: src, output_video_codec: 'libx264')
      expect(info.actual_output_video_codec).to be_nil
    end
  end

  describe '#actual_output_audio_codec' do
    it 'returns the target codec when transcoding (libfdk_aac → aac)' do
      info = described_class.new(media_source: mk_source, output_audio_codec: 'libfdk_aac')
      expect(info.actual_output_audio_codec).to eq('aac')
    end

    it 'returns the source codec when remuxing (output = copy)' do
      info = described_class.new(media_source: mk_source(audio_codec: 'flac'), output_audio_codec: 'copy')
      expect(info.actual_output_audio_codec).to eq('flac')
    end

    it 'falls back to the raw output codec for unknown encoders' do
      info = described_class.new(media_source: mk_source, output_audio_codec: 'eac3')
      expect(info.actual_output_audio_codec).to eq('eac3')
    end
  end
end
