require 'spec_helper'

RSpec.describe 'EncodingHelper batch-1 production gaps' do
  let(:caps) do
    Class.new do
      def supports_encoder?(name) %w[libx264 libx265 libsvtav1 aac].include?(name) end
      def supports_filter?(name)  %w[scale tonemapx zscale subtitles yadif bwdif setsar].include?(name) end
      def supports_hwaccel?(_)    false end
      def supports_decoder?(_)    true end
    end.new
  end

  def make_source(field_order: 'progressive', sar: '1:1', hdr: false)
    v = Jellyfin::Probing::MediaStream.new(
      index: 0, type: :video, codec: 'h264',
      width: 1920, height: 1080, frame_rate: 24.0,
      sample_aspect_ratio: sar, field_order: field_order,
      is_interlaced: %w[tt bb tb bt].include?(field_order),
      video_range: hdr ? 'HDR' : 'SDR',
      video_range_type: hdr ? 'HDR10' : 'SDR',
      color_primaries: hdr ? 'bt2020' : 'bt709',
      color_transfer:  hdr ? 'smpte2084' : 'bt709',
      color_space:     hdr ? 'bt2020nc' : 'bt709'
    )
    a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac', channels: 2, sample_rate: 48_000)
    Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: [v, a])
  end

  def make_job(**ov)
    src = make_source(field_order: ov.delete(:field_order) || 'progressive',
                      sar: ov.delete(:sar) || '1:1',
                      hdr: ov.delete(:hdr) || false)
    Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, **ov)
  end

  describe 'CRF rate control' do
    it 'defaults to CRF without an output bitrate cap' do
      job = make_job(output_video_codec: 'h264')
      job.instance_variable_set(:@output_video_bitrate, nil) # explicit no cap
      args = Jellyfin::Encoding::EncodingHelper.command_line_arguments(
        job, playlist_path: '/o.m3u8', segment_template: '/%d.ts', capabilities: caps
      )
      expect(args).to include('-crf', '23')
      expect(args).not_to include('-maxrate')
    end

    it 'uses capped-CRF when a bitrate ceiling is set' do
      job = make_job(output_video_codec: 'h264', output_video_bitrate: 4_000_000)
      args = Jellyfin::Encoding::EncodingHelper.command_line_arguments(
        job, playlist_path: '/o.m3u8', segment_template: '/%d.ts', capabilities: caps
      )
      expect(args).to include('-crf', '23')
      expect(args).to include('-maxrate', '4000000')
    end

    it 'switches to CBR when rate_control: :cbr is configured' do
      job = make_job(output_video_codec: 'h264', output_video_bitrate: 3_000_000)
      job.options.rate_control = :cbr
      args = Jellyfin::Encoding::EncodingHelper.command_line_arguments(
        job, playlist_path: '/o.m3u8', segment_template: '/%d.ts', capabilities: caps
      )
      expect(args).to include('-b:v', '3000000')
      expect(args).to include('-minrate', '3000000')
      expect(args).to include('-maxrate', '3000000')
    end

    it 'uses different CRF defaults per codec' do
      job_h264 = make_job(output_video_codec: 'h264')
      job_h264.instance_variable_set(:@output_video_bitrate, nil)
      job_h265 = make_job(output_video_codec: 'h265')
      job_h265.instance_variable_set(:@output_video_bitrate, nil)
      a264 = Jellyfin::Encoding::EncodingHelper.command_line_arguments(
        job_h264, playlist_path: '/o.m3u8', segment_template: '/%d.ts', capabilities: caps
      )
      a265 = Jellyfin::Encoding::EncodingHelper.command_line_arguments(
        job_h265, playlist_path: '/o.m3u8', segment_template: '/%d.ts', capabilities: caps
      )
      expect(a264).to include('-crf', '23')
      expect(a265).to include('-crf', '28')
    end
  end

  describe 'deinterlace' do
    it 'inserts yadif when input is interlaced' do
      job = make_job(field_order: 'tt')
      args = Jellyfin::Encoding::EncodingHelper.command_line_arguments(
        job, playlist_path: '/o.m3u8', segment_template: '/%d.ts', capabilities: caps
      )
      vf = args[args.index('-vf') + 1]
      expect(vf).to start_with('yadif=mode=send_frame')
    end

    it 'skips yadif for progressive input' do
      job = make_job(output_height: 720) # force a vf chain via scale
      args = Jellyfin::Encoding::EncodingHelper.command_line_arguments(
        job, playlist_path: '/o.m3u8', segment_template: '/%d.ts', capabilities: caps
      )
      idx = args.index('-vf')
      expect(idx).not_to be_nil
      expect(args[idx + 1]).not_to include('yadif')
    end

    it 'respects deinterlace_method: :bwdif' do
      job = make_job(field_order: 'tt')
      job.options.deinterlace_method = :bwdif
      args = Jellyfin::Encoding::EncodingHelper.command_line_arguments(
        job, playlist_path: '/o.m3u8', segment_template: '/%d.ts', capabilities: caps
      )
      vf = args[args.index('-vf') + 1]
      expect(vf).to start_with('bwdif=')
    end
  end

  describe 'anamorphic SAR correction' do
    it 'appends setsar=1 when SAR is non-square' do
      job = make_job(sar: '16:11')
      args = Jellyfin::Encoding::EncodingHelper.command_line_arguments(
        job, playlist_path: '/o.m3u8', segment_template: '/%d.ts', capabilities: caps
      )
      vf = args[args.index('-vf') + 1] rescue nil
      expect(vf).to include('setsar=1')
    end

    it 'skips setsar for square pixels' do
      job = make_job(sar: '1:1', output_height: 720)
      args = Jellyfin::Encoding::EncodingHelper.command_line_arguments(
        job, playlist_path: '/o.m3u8', segment_template: '/%d.ts', capabilities: caps
      )
      vf = args[args.index('-vf') + 1] rescue nil
      expect(vf).not_to include('setsar')
    end
  end

  describe 'B-frames and ref frames' do
    it 'emits -bf and -refs from EncodingOptions for libx264' do
      job = make_job(output_video_codec: 'h264')
      job.options.b_frames = 4
      job.options.ref_frames = 5
      args = Jellyfin::Encoding::EncodingHelper.command_line_arguments(
        job, playlist_path: '/o.m3u8', segment_template: '/%d.ts', capabilities: caps
      )
      expect(args).to include('-bf', '4')
      expect(args).to include('-refs', '5')
    end

    it 'rolls B-frames + ref-frames into -x265-params for libx265' do
      job = make_job(output_video_codec: 'h265')
      job.options.b_frames = 8
      job.options.ref_frames = 4
      args = Jellyfin::Encoding::EncodingHelper.command_line_arguments(
        job, playlist_path: '/o.m3u8', segment_template: '/%d.ts', capabilities: caps
      )
      x265_idx = args.index('-x265-params')
      expect(x265_idx).not_to be_nil
      expect(args[x265_idx + 1]).to include('bframes=8').and(include('ref=4'))
    end
  end

  describe 'H.264 level normalization' do
    it 'picks 4.1 for 1080p at 30fps' do
      src = make_source
      src.video_streams.first.frame_rate = 30.0
      job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, output_video_codec: 'h264')
      args = Jellyfin::Encoding::EncodingHelper.command_line_arguments(
        job, playlist_path: '/o.m3u8', segment_template: '/%d.ts', capabilities: caps
      )
      idx = args.index('-level')
      expect(idx).not_to be_nil
      expect(args[idx + 1]).to eq('4.1')
    end

    it 'picks 5.2 for 4K at 60fps' do
      v = Jellyfin::Probing::MediaStream.new(
        index: 0, type: :video, codec: 'h264', width: 3840, height: 2160,
        frame_rate: 60.0, sample_aspect_ratio: '1:1', field_order: 'progressive',
        is_interlaced: false, video_range: 'SDR', video_range_type: 'SDR'
      )
      src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: [v])
      job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, output_video_codec: 'h264')
      args = Jellyfin::Encoding::EncodingHelper.command_line_arguments(
        job, playlist_path: '/o.m3u8', segment_template: '/%d.ts', capabilities: caps
      )
      idx = args.index('-level')
      expect(args[idx + 1]).to eq('5.2')
    end
  end

  describe 'HDR metadata passthrough' do
    it 'forwards HDR color flags when tone-mapping is disabled (HDR-out)' do
      job = make_job(hdr: true)
      job.options.enable_tonemapping = false
      args = Jellyfin::Encoding::EncodingHelper.command_line_arguments(
        job, playlist_path: '/o.m3u8', segment_template: '/%d.ts', capabilities: caps
      )
      expect(args).to include('-color_primaries', 'bt2020')
      expect(args).to include('-color_trc', 'smpte2084')
      expect(args).to include('-colorspace', 'bt2020nc')
    end

    it 'omits HDR flags when tone-mapping is on (SDR-out)' do
      job = make_job(hdr: true) # tone-mapping is on by default
      args = Jellyfin::Encoding::EncodingHelper.command_line_arguments(
        job, playlist_path: '/o.m3u8', segment_template: '/%d.ts', capabilities: caps
      )
      expect(args).not_to include('-color_primaries')
    end

    it 'omits HDR flags for SDR input' do
      job = make_job
      args = Jellyfin::Encoding::EncodingHelper.command_line_arguments(
        job, playlist_path: '/o.m3u8', segment_template: '/%d.ts', capabilities: caps
      )
      expect(args).not_to include('-color_primaries')
    end
  end
end
