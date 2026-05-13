require 'spec_helper'

RSpec.describe Jellyfin::Encoding::Hwaccel::Amf do
  let(:caps) do
    Class.new do
      def supports_encoder?(n); %w[h264_amf hevc_amf av1_amf].include?(n); end
      def supports_filter?(n); %w[tonemap_opencl].include?(n); end
      def supports_hwaccel?(n); %w[amf d3d11va].include?(n); end
      def supports_decoder?(_); true; end
    end.new
  end

  it 'picks the right encoder per codec' do
    expect(described_class.encoder_for('h264', caps)).to eq('h264_amf')
    expect(described_class.encoder_for('hevc', caps)).to eq('hevc_amf')
    expect(described_class.encoder_for('av1',  caps)).to eq('av1_amf')
  end

  it 'emits d3d11va hwaccel args' do
    args = described_class.decode_args(double('job'), caps)
    expect(args).to include('-hwaccel', 'd3d11va')
    expect(args).to include('-hwaccel_output_format', 'd3d11')
  end

  it 'bridges to OpenCL for tonemapping' do
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'hevc',
      video_range_type: 'HDR10', pixel_format: 'yuv420p10le', bit_depth: 10)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: [v])
    job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, output_video_codec: 'h265')
    chain = described_class.filter_chain(job, caps)
    expect(chain).to include('tonemap_opencl=')
    expect(chain).to include('hwmap=derive_device=d3d11va:reverse=1')
  end
end

RSpec.describe Jellyfin::Encoding::Hwaccel::Rkmpp do
  let(:caps) do
    Class.new do
      def supports_encoder?(n); %w[h264_rkmpp hevc_rkmpp].include?(n); end
      def supports_filter?(n); n == 'tonemap_rkrga'; end
      def supports_hwaccel?(n); n == 'rkmpp'; end
      def supports_decoder?(_); true; end
    end.new
  end

  it 'emits the drm_prime hwaccel chain' do
    args = described_class.decode_args(double('job'), caps)
    expect(args).to include('-hwaccel', 'rkmpp')
    expect(args).to include('-hwaccel_output_format', 'drm_prime')
    expect(args).to include('-afbc', 'rga')
  end

  it 'uses tonemap_rkrga for HDR sources when present' do
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'hevc',
      video_range_type: 'HDR10', pixel_format: 'yuv420p10le', bit_depth: 10)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: [v])
    job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, output_video_codec: 'h265')
    chain = described_class.filter_chain(job, caps)
    expect(chain).to include('tonemap_rkrga=')
  end
end

RSpec.describe Jellyfin::Encoding::Hwaccel::FilterChain do
  let(:caps) do
    Class.new do
      def supports_encoder?(_); true; end
      def supports_filter?(_); true; end
      def supports_hwaccel?(_); true; end
      def supports_decoder?(_); true; end
    end.new
  end

  def make_job(burn: false)
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264')
    streams = [v]
    sub = nil
    if burn
      sub = Jellyfin::Probing::MediaStream.new(index: 1, type: :subtitle, codec: 'hdmv_pgs_subtitle')
      streams << sub
    end
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: streams)
    Jellyfin::Encoding::EncodingJobInfo.new(media_source: src,
      output_video_codec: 'h264',
      subtitle_stream: sub, subtitle_method: burn ? :encode : :soft)
  end

  it 'returns a Chain struct with main/sub/overlay lists (upstream cs:3777)' do
    chain = described_class.for(accel_type: :software, job: make_job, vid_encoder: 'libx264', capabilities: caps)
    expect(chain).to be_a(described_class::Chain)
    expect(chain.main_filters).to be_an(Array)
    expect(chain.sub_filters).to eq([])
    expect(chain.overlay_filters).to eq([])
  end

  it 'dispatches to NVENC backend for :nvenc accel type' do
    chain = described_class.for(accel_type: :nvenc, job: make_job, vid_encoder: 'h264_nvenc', capabilities: caps)
    expect(chain).to be_a(described_class::Chain)
  end

  it 'falls back to software when the accel backend is unavailable' do
    bad_caps = Class.new do
      def supports_encoder?(_); false; end
      def supports_filter?(_); false; end
      def supports_hwaccel?(_); false; end
      def supports_decoder?(_); false; end
    end.new
    chain = described_class.for(accel_type: :nvenc, job: make_job, vid_encoder: 'h264_nvenc', capabilities: bad_caps)
    expect(chain).to be_a(described_class::Chain)
  end

  it 'includes the HW subtitle overlay filter when burn + HW backend pair up' do
    chain = described_class.for(accel_type: :nvenc, job: make_job(burn: true),
                                vid_encoder: 'h264_nvenc', capabilities: caps)
    expect(chain.sub_filters.first).to start_with('overlay_cuda')
  end
end

RSpec.describe Jellyfin::Encoding::Hwaccel::Decoder do
  let(:caps) do
    Class.new do
      def supports_decoder?(name)
        %w[h264_qsv hevc_qsv h264_cuvid hevc_cuvid h264_amf h264_vaapi h264_videotoolbox hevc_videotoolbox h264_rkmpp].include?(name)
      end
    end.new
  end

  it 'GetHwDecoderName picks h264_qsv for QSV + h264 source (upstream cs:6464)' do
    expect(described_class.for(accel_type: :qsv, codec: 'h264', capabilities: caps)).to eq('h264_qsv')
  end

  it 'picks h264_cuvid for NVENC' do
    expect(described_class.for(accel_type: :nvenc, codec: 'h264', capabilities: caps)).to eq('h264_cuvid')
  end

  it 'returns nil when the decoder is missing from capabilities' do
    expect(described_class.for(accel_type: :amf, codec: 'hevc', capabilities: caps)).to be_nil # hevc_amf not in caps
  end

  it 'returns nil for unknown codec' do
    expect(described_class.for(accel_type: :qsv, codec: 'theora', capabilities: caps)).to be_nil
  end

  it 'GetHwaccelType maps backends to ffmpeg -hwaccel values (upstream cs:6522)' do
    expect(described_class.hwaccel_type(:qsv)).to eq('qsv')
    expect(described_class.hwaccel_type(:nvenc)).to eq('cuda')
    expect(described_class.hwaccel_type(:amf)).to eq('d3d11va')
    expect(described_class.hwaccel_type(:vaapi)).to eq('vaapi')
    expect(described_class.hwaccel_type(:videotoolbox)).to eq('videotoolbox')
    expect(described_class.hwaccel_type(:rkmpp)).to eq('rkmpp')
  end

  it 'picks hevc_videotoolbox on Apple Silicon for HEVC' do
    expect(described_class.for(accel_type: :videotoolbox, codec: 'hevc', capabilities: caps)).to eq('hevc_videotoolbox')
  end

  it 'picks h264_rkmpp on Rockchip SBC' do
    expect(described_class.for(accel_type: :rkmpp, codec: 'h264', capabilities: caps)).to eq('h264_rkmpp')
  end
end
