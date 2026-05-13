require 'spec_helper'

RSpec.describe Jellyfin::Encoding::DolbyVision do
  def dv_stream(profile: 8, range_type: 'DOVI')
    Jellyfin::Probing::MediaStream.new(
      index: 0, type: :video, codec: 'hevc', width: 3840, height: 2160,
      pixel_format: 'yuv420p10le', bit_depth: 10,
      video_range_type: range_type, dovi_profile: profile,
      dovi_rpu_present: true, dovi_bl_present: true
    )
  end

  describe '.present?' do
    it 'is true when the stream has a DOVI side-data record' do
      expect(described_class.present?(dv_stream)).to be(true)
    end

    it 'is false for plain HDR10 streams' do
      v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'hevc',
        video_range_type: 'HDR10')
      expect(described_class.present?(v)).to be(false)
    end
  end

  describe '.cross_compatible?' do
    it 'is true for profiles 7/8/8.1/8.4' do
      expect(described_class.cross_compatible?(dv_stream(profile: 7))).to be(true)
      expect(described_class.cross_compatible?(dv_stream(profile: 8))).to be(true)
      expect(described_class.cross_compatible?(dv_stream(profile: 81))).to be(true)
      expect(described_class.cross_compatible?(dv_stream(profile: 84))).to be(true)
    end

    it 'is false for profile 5 (DV-only, no HDR10 fallback)' do
      expect(described_class.cross_compatible?(dv_stream(profile: 5))).to be(false)
    end
  end

  describe '.passthrough_input_args' do
    it 'forces ffmpeg to accept the non-standard DV NAL types' do
      expect(described_class.passthrough_input_args).to eq(['-strict', 'unofficial'])
    end
  end

  describe '.x265_params' do
    it 'emits dolby-vision-profile' do
      params = described_class.x265_params(dv_stream(profile: 8))
      expect(params).to include('dolby-vision-profile=8')
    end

    it 'appends RPU path when an extracted file is provided' do
      params = described_class.x265_params(dv_stream(profile: 8), rpu_file: '/tmp/rpu.bin')
      expect(params).to include('dolby-vision-rpu=/tmp/rpu.bin')
    end

    it 'sets vbv-bufsize for cross-compatible profiles' do
      params = described_class.x265_params(dv_stream(profile: 81))
      expect(params).to include('vbv-bufsize=160000')
    end

    it 'returns nil for non-DV streams' do
      v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'hevc',
        video_range_type: 'HDR10')
      expect(described_class.x265_params(v)).to be_nil
    end
  end

  describe '.output_args' do
    it 'emits -dolbyvision true for DV streams' do
      expect(described_class.output_args(dv_stream)).to eq(['-dolbyvision', 'true'])
    end

    it 'is empty for non-DV streams' do
      v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'hevc')
      expect(described_class.output_args(v)).to eq([])
    end
  end
end

RSpec.describe Jellyfin::Encoding::EncodingHelper do
  let(:caps) do
    Class.new do
      def supports_encoder?(name) %w[libx264 libx265 aac].include?(name) end
      def supports_filter?(_) true end
      def supports_hwaccel?(_) false end
      def supports_decoder?(_) true end
    end.new
  end

  it 'splices -strict unofficial before -i for Dolby Vision sources' do
    v = Jellyfin::Probing::MediaStream.new(
      index: 0, type: :video, codec: 'hevc', width: 3840, height: 2160,
      pixel_format: 'yuv420p10le', bit_depth: 10,
      video_range_type: 'DOVI', dovi_profile: 8, dovi_rpu_present: true
    )
    a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac',
      channels: 2, sample_rate: 48_000)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: [v, a])
    job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src,
      output_video_codec: 'h265', output_audio_codec: 'aac')

    args = described_class.command_line_arguments(
      job, playlist_path: '/tmp/p.m3u8', segment_template: '/tmp/%d.ts', capabilities: caps
    )
    strict_idx = args.index('-strict')
    i_idx = args.index('-i')
    expect(strict_idx).not_to be_nil
    expect(strict_idx).to be < i_idx
    expect(args[strict_idx + 1]).to eq('unofficial')
  end

  it 'forwards -dolbyvision true on the output when DV is preserved' do
    v = Jellyfin::Probing::MediaStream.new(
      index: 0, type: :video, codec: 'hevc', width: 3840, height: 2160,
      pixel_format: 'yuv420p10le', bit_depth: 10,
      color_primaries: 'bt2020', color_transfer: 'smpte2084', color_space: 'bt2020nc',
      video_range: 'HDR', video_range_type: 'DOVI', dovi_profile: 8
    )
    a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac',
      channels: 2, sample_rate: 48_000)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: [v, a])
    job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src,
      output_video_codec: 'h265', output_audio_codec: 'aac')
    job.options.enable_tonemapping = false

    args = described_class.command_line_arguments(
      job, playlist_path: '/tmp/p.m3u8', segment_template: '/tmp/%d.ts', capabilities: caps
    )
    expect(args).to include('-dolbyvision', 'true')
  end

  it 'adds dolby-vision params to x265-params for DV transcode' do
    v = Jellyfin::Probing::MediaStream.new(
      index: 0, type: :video, codec: 'hevc', width: 3840, height: 2160,
      pixel_format: 'yuv420p10le', bit_depth: 10,
      video_range_type: 'DOVI', dovi_profile: 8
    )
    a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac',
      channels: 2, sample_rate: 48_000)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: [v, a])
    job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src,
      output_video_codec: 'h265', output_audio_codec: 'aac')
    job.options.enable_tonemapping = false

    args = described_class.command_line_arguments(
      job, playlist_path: '/tmp/p.m3u8', segment_template: '/tmp/%d.ts', capabilities: caps
    )
    idx = args.index('-x265-params')
    expect(idx).not_to be_nil
    expect(args[idx + 1]).to include('dolby-vision-profile=8')
  end
end
