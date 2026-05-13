require 'spec_helper'

RSpec.describe Jellyfin::Encoding::EncodingHelper do
  # Fake capabilities — saves us from shelling out in unit tests.
  let(:caps) do
    Class.new do
      def supports_encoder?(name) %w[libx264 libx265 aac].include?(name) end
      def supports_filter?(name)  %w[scale tonemapx zscale subtitles].include?(name) end
      def supports_hwaccel?(_)    false end
      def supports_decoder?(_)    true end
    end.new
  end

  def make_source(**overrides)
    streams = []
    streams << Jellyfin::Probing::MediaStream.new(
      index: 0, type: :video, codec: 'h264', width: 1920, height: 1080,
      frame_rate: 24.0, video_range: 'SDR', video_range_type: 'SDR'
    )
    streams << Jellyfin::Probing::MediaStream.new(
      index: 1, type: :audio, codec: 'aac', channels: 6, sample_rate: 48_000, bit_rate: 384_000
    )
    if overrides[:hdr]
      streams[0] = Jellyfin::Probing::MediaStream.new(
        index: 0, type: :video, codec: 'hevc', width: 3840, height: 2160,
        frame_rate: 24.0, video_range: 'HDR', video_range_type: 'HDR10', pixel_format: 'yuv420p10le'
      )
    end
    Jellyfin::Probing::MediaSourceInfo.new(
      path: '/srv/media/sample.mkv', container: 'mkv', protocol: 'file',
      run_time_ticks: 600 * 10_000_000, streams: streams
    )
  end

  def make_job(**overrides)
    Jellyfin::Encoding::EncodingJobInfo.new(media_source: make_source(**overrides), **overrides.except(:hdr))
  end

  describe '#command_line_arguments' do
    it 'produces a runnable HLS arg list for a typical H.264/AAC job' do
      job = make_job(output_video_bitrate: 3_000_000, output_audio_bitrate: 128_000)
      args = described_class.command_line_arguments(
        job, playlist_path: '/tmp/out.m3u8', segment_template: '/tmp/%d.ts', capabilities: caps
      )
      flat = args.join(' ')
      expect(flat).to include('-i /srv/media/sample.mkv')
      expect(flat).to include('-c:v libx264')
      expect(flat).to include('-c:a aac')
      expect(flat).to include('-f hls')
      expect(args.last).to eq('/tmp/out.m3u8')
    end

    it 'scales the maxrate cap by 0.6 for h265 (CRF rate control)' do
      job = make_job(output_video_codec: 'h265', output_video_bitrate: 5_000_000)
      args = described_class.command_line_arguments(
        job, playlist_path: '/tmp/o.m3u8', segment_template: '/tmp/%d.ts', capabilities: caps
      )
      expect(args).to include('-c:v', 'libx265')
      expect(args).to include('-crf', '28')         # h265 default CRF
      expect(args).to include('-maxrate', '3000000') # 5M * 0.6
    end

    it 'emits a scale filter when output_height is set below source' do
      job = make_job(output_height: 720)
      args = described_class.command_line_arguments(
        job, playlist_path: '/tmp/o.m3u8', segment_template: '/tmp/%d.ts', capabilities: caps
      )
      vf = args[args.index('-vf') + 1]
      expect(vf).to include("scale=-2:'min(720,ih)'")
    end

    it 'inserts an HDR tonemap chain when input is HDR10 and tonemapx is supported' do
      job = make_job(hdr: true)
      args = described_class.command_line_arguments(
        job, playlist_path: '/tmp/o.m3u8', segment_template: '/tmp/%d.ts', capabilities: caps
      )
      vf = args[args.index('-vf') + 1]
      expect(vf).to include('tonemapx=tonemap=bt2390')
      expect(vf).to include('peak=100')
    end

    it 'falls back to zscale chain when tonemapx is missing' do
      no_tonemapx = Class.new(caps.class) do
        def supports_filter?(name); %w[scale zscale subtitles].include?(name); end
      end.new
      job = make_job(hdr: true)
      args = described_class.command_line_arguments(
        job, playlist_path: '/tmp/o.m3u8', segment_template: '/tmp/%d.ts', capabilities: no_tonemapx
      )
      vf = args[args.index('-vf') + 1]
      expect(vf).to include('zscale=t=linear')
      expect(vf).to include('tonemap=tonemap=bt2390')
    end

    it 'downmixes 5.1 → stereo by default' do
      job = make_job
      args = described_class.command_line_arguments(
        job, playlist_path: '/tmp/o.m3u8', segment_template: '/tmp/%d.ts', capabilities: caps
      )
      expect(args).to include('-ac', '2')
    end

    it 'sets keyframes aligned to segment_length' do
      job = make_job(segment_length: 4)
      args = described_class.command_line_arguments(
        job, playlist_path: '/tmp/o.m3u8', segment_template: '/tmp/%d.ts', capabilities: caps
      )
      expect(args).to include('-g', '96')  # 4s * 24fps
      expect(args).to include('-force_key_frames', 'expr:gte(t,n_forced*4)')
    end

    it 'respects start_time_ticks via -ss' do
      job = make_job(start_time_ticks: 30 * 10_000_000)
      args = described_class.command_line_arguments(
        job, playlist_path: '/tmp/o.m3u8', segment_template: '/tmp/%d.ts', capabilities: caps
      )
      expect(args).to include('-ss')
      idx = args.index('-ss')
      expect(args[idx + 1]).to eq('30.000')
    end
  end

  describe '.can_stream_copy_video? / .can_stream_copy_audio?' do
    it 'allows video stream-copy when codec matches and bitrate is OK' do
      job = make_job(output_video_codec: 'h264', output_video_bitrate: 10_000_000)
      job.video_stream.bit_rate = 4_500_000
      expect(Jellyfin::Encoding::CodecSelector.can_stream_copy_video?(job)).to be(true)
    end

    it 'rejects video stream-copy when source bitrate exceeds target by >10%' do
      job = make_job(output_video_codec: 'h264', output_video_bitrate: 1_000_000)
      job.video_stream.bit_rate = 5_000_000
      expect(Jellyfin::Encoding::CodecSelector.can_stream_copy_video?(job)).to be(false)
    end

    it 'rejects video stream-copy when source is taller than target' do
      job = make_job(output_video_codec: 'h264', output_height: 720)
      expect(Jellyfin::Encoding::CodecSelector.can_stream_copy_video?(job)).to be(false)
    end
  end
end
