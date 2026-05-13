require 'spec_helper'

RSpec.describe Jellyfin::Probing::ProbeResultNormalizer, '— batch B depth' do
  let(:path) { '/srv/media/x.mkv' }

  describe 'bitrate fallback' do
    it 'derives effective_bit_rate from size / duration when format.bit_rate is absent' do
      json = {
        'format' => { 'format_name' => 'matroska', 'duration' => '600.0', 'size' => '750000000' },
        'streams' => [], 'chapters' => []
      }
      info = described_class.call(json, path: path)
      expect(info.bit_rate).to be_nil
      expect(info.effective_bit_rate).to eq(10_000_000) # 750MB * 8 / 600s
    end

    it 'returns format.bit_rate when present' do
      json = {
        'format' => { 'format_name' => 'mp4', 'duration' => '60', 'bit_rate' => '5000000' },
        'streams' => [], 'chapters' => []
      }
      info = described_class.call(json, path: path)
      expect(info.effective_bit_rate).to eq(5_000_000)
    end
  end

  describe 'HDR static metadata' do
    it 'extracts MaxCLL and MaxFALL from Content light level side data' do
      v = base_video.merge(
        'side_data_list' => [{
          'side_data_type' => 'Content light level metadata',
          'max_content' => 4000, 'max_average' => 400
        }],
        'color_transfer' => 'smpte2084'
      )
      json = { 'format' => { 'format_name' => 'matroska' }, 'streams' => [v], 'chapters' => [] }
      info = described_class.call(json, path: path)
      stream = info.video_streams.first
      expect(stream.max_cll).to eq(4000)
      expect(stream.max_fall).to eq(400)
    end

    it 'extracts mastering display metadata' do
      v = base_video.merge(
        'side_data_list' => [{
          'side_data_type' => 'Mastering display metadata',
          'red_x' => '35400/50000', 'red_y' => '14600/50000',
          'green_x' => '13250/50000', 'green_y' => '34500/50000',
          'blue_x' => '7500/50000', 'blue_y' => '3000/50000',
          'white_point_x' => '15635/50000', 'white_point_y' => '16450/50000',
          'min_luminance' => '50/10000', 'max_luminance' => '10000000/10000'
        }],
        'color_transfer' => 'smpte2084'
      )
      json = { 'format' => { 'format_name' => 'matroska' }, 'streams' => [v], 'chapters' => [] }
      info = described_class.call(json, path: path)
      md = info.video_streams.first.mastering_display
      expect(md['min_luminance']).to eq('50/10000')
      expect(md['max_luminance']).to eq('10000000/10000')
    end
  end

  describe 'Dolby Vision details' do
    it 'extracts DOVI profile + RPU/BL/EL presence flags' do
      v = base_video.merge(
        'side_data_list' => [{
          'side_data_type' => 'DOVI configuration record',
          'dv_profile' => 7, 'rpu_present_flag' => 1, 'bl_present_flag' => 1, 'el_present_flag' => 1
        }]
      )
      json = { 'format' => { 'format_name' => 'matroska' }, 'streams' => [v], 'chapters' => [] }
      info = described_class.call(json, path: path)
      s = info.video_streams.first
      expect(s.dovi_profile).to eq(7)
      expect(s.dovi_rpu_present).to eq(1)
      expect(s.dovi_bl_present).to eq(1)
      expect(s.dovi_el_present).to eq(1)
      expect(s.video_range_type).to eq('DOVI')
    end
  end

  describe 'CFR vs VFR detection' do
    it 'flags is_vfr when r_frame_rate and avg_frame_rate diverge >5%' do
      v = base_video.merge('r_frame_rate' => '30/1', 'avg_frame_rate' => '24/1')
      json = { 'format' => { 'format_name' => 'mp4' }, 'streams' => [v], 'chapters' => [] }
      info = described_class.call(json, path: path)
      expect(info.video_streams.first.is_vfr).to be(true)
    end

    it 'leaves is_vfr false for matched rates' do
      v = base_video.merge('r_frame_rate' => '24/1', 'avg_frame_rate' => '24/1')
      json = { 'format' => { 'format_name' => 'mp4' }, 'streams' => [v], 'chapters' => [] }
      info = described_class.call(json, path: path)
      expect(info.video_streams.first.is_vfr).to be(false)
    end
  end

  describe 'bit depth derivation' do
    it 'reads bits_per_raw_sample when present' do
      v = base_video.merge('bits_per_raw_sample' => '10', 'pix_fmt' => 'yuv420p10le')
      json = { 'format' => { 'format_name' => 'mp4' }, 'streams' => [v], 'chapters' => [] }
      info = described_class.call(json, path: path)
      expect(info.video_streams.first.bit_depth).to eq(10)
    end

    it 'derives bit depth from pixel format when bits_per_raw_sample is absent' do
      v = base_video.merge('pix_fmt' => 'yuv420p12le')
      json = { 'format' => { 'format_name' => 'mp4' }, 'streams' => [v], 'chapters' => [] }
      info = described_class.call(json, path: path)
      expect(info.video_streams.first.bit_depth).to eq(12)
    end

    it 'defaults to 8-bit' do
      v = base_video.merge('pix_fmt' => 'yuv420p')
      json = { 'format' => { 'format_name' => 'mp4' }, 'streams' => [v], 'chapters' => [] }
      info = described_class.call(json, path: path)
      expect(info.video_streams.first.bit_depth).to eq(8)
    end
  end

  describe 'multiple programs (MPEG-TS PMT)' do
    it 'parses programs into a list with stream indexes' do
      json = {
        'format' => { 'format_name' => 'mpegts' },
        'streams' => [], 'chapters' => [],
        'programs' => [
          { 'program_id' => 100, 'program_num' => 1, 'nb_streams' => 2,
            'streams' => [{ 'index' => 0 }, { 'index' => 1 }] },
          { 'program_id' => 200, 'program_num' => 2, 'nb_streams' => 2,
            'streams' => [{ 'index' => 2 }, { 'index' => 3 }] }
        ]
      }
      info = described_class.call(json, path: path)
      expect(info.programs.size).to eq(2)
      expect(info.programs[1][:streams]).to eq([2, 3])
    end
  end

  describe 'channel_layout extraction' do
    it 'captures channel_layout on audio streams' do
      a = {
        'index' => 0, 'codec_type' => 'audio', 'codec_name' => 'aac',
        'channels' => 6, 'channel_layout' => '5.1', 'sample_rate' => '48000'
      }
      json = { 'format' => { 'format_name' => 'mp4' }, 'streams' => [a], 'chapters' => [] }
      info = described_class.call(json, path: path)
      expect(info.audio_streams.first.channel_layout).to eq('5.1')
    end
  end

  def base_video
    {
      'index' => 0, 'codec_type' => 'video', 'codec_name' => 'hevc',
      'profile' => 'Main 10', 'width' => 3840, 'height' => 2160,
      'pix_fmt' => 'yuv420p10le', 'r_frame_rate' => '24/1', 'avg_frame_rate' => '24/1',
      'disposition' => { 'default' => 1 }
    }
  end
end
