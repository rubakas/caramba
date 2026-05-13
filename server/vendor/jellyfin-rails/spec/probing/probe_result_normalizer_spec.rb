require 'spec_helper'

RSpec.describe Jellyfin::Probing::ProbeResultNormalizer do
  describe '.call' do
    let(:path) { '/srv/media/sample.mkv' }

    context 'with a typical h264/aac mkv response' do
      let(:json) do
        {
          'format' => {
            'format_name' => 'matroska,webm',
            'duration' => '120.5',
            'bit_rate' => '5000000',
            'size' => '75312500'
          },
          'streams' => [
            { 'index' => 0, 'codec_type' => 'video', 'codec_name' => 'h264',
              'profile' => 'High', 'width' => 1920, 'height' => 1080,
              'pix_fmt' => 'yuv420p', 'r_frame_rate' => '24/1', 'avg_frame_rate' => '24/1',
              'color_transfer' => 'bt709', 'bit_rate' => '4500000', 'is_avc' => 'true',
              'disposition' => { 'default' => 1 } },
            { 'index' => 1, 'codec_type' => 'audio', 'codec_name' => 'aac',
              'channels' => 6, 'sample_rate' => '48000', 'bit_rate' => '500000',
              'tags' => { 'language' => 'eng' }, 'disposition' => { 'default' => 1 } },
            { 'index' => 2, 'codec_type' => 'subtitle', 'codec_name' => 'subrip',
              'tags' => { 'language' => 'eng', 'title' => 'English' },
              'disposition' => { 'default' => 0 } }
          ],
          'chapters' => [
            { 'id' => 0, 'start_time' => '0.0', 'end_time' => '60.0', 'tags' => { 'title' => 'Intro' } }
          ]
        }
      end

      subject(:info) { described_class.call(json, path: path) }

      it 'normalizes container name to mkv' do
        expect(info.container).to eq('mkv')
      end

      it 'computes run_time_ticks' do
        expect(info.run_time_ticks).to eq(1_205_000_000)
        expect(info.duration_seconds).to eq(120.5)
      end

      it 'parses the video stream attributes' do
        v = info.video_streams.first
        expect(v.codec).to eq('h264')
        expect(v.width).to eq(1920)
        expect(v.height).to eq(1080)
        expect(v.frame_rate).to eq(24.0)
        expect(v.video_range).to eq('SDR')
        expect(v.is_default).to be(true)
      end

      it 'parses the audio stream attributes' do
        a = info.audio_streams.first
        expect(a.codec).to eq('aac')
        expect(a.channels).to eq(6)
        expect(a.sample_rate).to eq(48_000)
        expect(a.language).to eq('eng')
      end

      it 'parses subtitle streams' do
        s = info.subtitle_streams.first
        expect(s.codec).to eq('subrip')
        expect(s.language).to eq('eng')
        expect(s.title).to eq('English')
      end

      it 'parses chapters' do
        expect(info.chapters.first[:title]).to eq('Intro')
        expect(info.chapters.first[:start_time]).to eq(0.0)
      end
    end

    context 'with HDR side data' do
      it 'detects HDR10' do
        json = base_json.merge('streams' => [hdr_stream('color_transfer' => 'smpte2084')])
        info = described_class.call(json, path: path)
        expect(info.video_streams.first.video_range).to eq('HDR')
        expect(info.video_streams.first.video_range_type).to eq('HDR10')
        expect(info.video_streams.first.hdr?).to be(true)
      end

      it 'detects HLG' do
        json = base_json.merge('streams' => [hdr_stream('color_transfer' => 'arib-std-b67')])
        info = described_class.call(json, path: path)
        expect(info.video_streams.first.video_range_type).to eq('HLG')
      end

      it 'detects Dolby Vision via side data' do
        json = base_json.merge('streams' => [hdr_stream('side_data_list' => [{ 'side_data_type' => 'DOVI configuration record' }])])
        info = described_class.call(json, path: path)
        expect(info.video_streams.first.video_range_type).to eq('DOVI')
      end

      it 'detects HDR10+ via side data' do
        json = base_json.merge('streams' => [hdr_stream(
          'side_data_list' => [{ 'side_data_type' => 'HDR Dynamic Metadata SMPTE2094-40 (HDR10+)' }]
        )])
        info = described_class.call(json, path: path)
        expect(info.video_streams.first.video_range_type).to eq('HDR10Plus')
      end
    end

    def base_json
      { 'format' => { 'format_name' => 'matroska' }, 'streams' => [], 'chapters' => [] }
    end

    def hdr_stream(overrides = {})
      {
        'index' => 0, 'codec_type' => 'video', 'codec_name' => 'hevc',
        'width' => 3840, 'height' => 2160, 'pix_fmt' => 'yuv420p10le',
        'r_frame_rate' => '24/1', 'avg_frame_rate' => '24/1',
        'disposition' => { 'default' => 1 }
      }.merge(overrides)
    end
  end
end
