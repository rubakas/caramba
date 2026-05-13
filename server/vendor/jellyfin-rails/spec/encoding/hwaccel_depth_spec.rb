require 'spec_helper'

# Tests that don't need real hardware — they exercise the arg-string generation
# given mocked capabilities. Driver detection paths that read /sys/ are tagged
# `:requires_linux` and skipped on non-Linux.
RSpec.describe 'HW accel depth' do
  def caps(encoders: [], filters: [], hwaccels: [])
    e, f, h = encoders, filters, hwaccels
    obj = Object.new
    obj.define_singleton_method(:supports_encoder?) { |n| e.include?(n) }
    obj.define_singleton_method(:supports_filter?)  { |n| f.include?(n) }
    obj.define_singleton_method(:supports_hwaccel?) { |n| h.include?(n) }
    obj.define_singleton_method(:supports_decoder?) { |_| true }
    obj
  end

  def hdr_job(codec: 'h264', pix: 'yuv420p10le')
    v = Jellyfin::Probing::MediaStream.new(
      index: 0, type: :video, codec: 'hevc',
      width: 3840, height: 2160, frame_rate: 24.0, pixel_format: pix,
      video_range: 'HDR', video_range_type: 'HDR10',
      sample_aspect_ratio: '1:1', field_order: 'progressive', is_interlaced: false,
      color_primaries: 'bt2020', color_transfer: 'smpte2084', color_space: 'bt2020nc'
    )
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: [v])
    opts = Jellyfin::Encoding::EncodingOptions.new.tap do |o|
      o.enable_hardware_encoding = true
      o.hardware_acceleration_type = :nvenc
    end
    Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, options: opts, output_video_codec: codec)
  end

  describe Jellyfin::Encoding::Hwaccel::Nvenc do
    it 'maps preset symbolic names to p1..p7 numeric form' do
      job = hdr_job
      job.options.encoder_preset = 'slow'
      expect(described_class.encoder_args(job)).to include('-preset', 'p5')
    end

    it 'enables spatial + temporal AQ' do
      args = described_class.encoder_args(hdr_job)
      expect(args).to include('-spatial_aq', '1')
      expect(args).to include('-temporal_aq', '1')
    end

    it 'passes look-ahead from EncodingOptions' do
      job = hdr_job
      job.options.lookahead = 32
      expect(described_class.encoder_args(job)).to include('-rc-lookahead', '32')
    end

    it 'switches to Main10 + p010le for HEVC 10-bit HDR' do
      args = described_class.encoder_args(hdr_job(codec: 'h265', pix: 'yuv420p10le'))
      expect(args).to include('-profile:v', 'main10')
      expect(args).to include('-pix_fmt', 'p010le')
    end

    it 'inserts CUDA→OpenCL tonemap bridge when tonemap_cuda is unavailable' do
      c = caps(encoders: %w[h264_nvenc], filters: %w[tonemap_opencl scale_cuda], hwaccels: %w[cuda])
      chain = described_class.filter_chain(hdr_job, c)
      expect(chain).to include('hwmap=derive_device=opencl')
      expect(chain).to include('tonemap_opencl')
      expect(chain).to include('hwmap=derive_device=cuda:reverse=1')
    end

    it 'pins to multi-GPU via JELLYFIN_NVENC_GPU env var' do
      original = ENV['JELLYFIN_NVENC_GPU']
      ENV['JELLYFIN_NVENC_GPU'] = '1'
      c = caps(hwaccels: %w[cuda])
      expect(described_class.decode_args(hdr_job, c)).to include('-hwaccel_device', '1')
    ensure
      ENV['JELLYFIN_NVENC_GPU'] = original
    end
  end

  describe Jellyfin::Encoding::Hwaccel::Vaapi do
    it 'uses ICQ rate control on Intel + CRF mode' do
      ENV['JELLYFIN_VAAPI_DRIVER'] = 'iHD'
      job = hdr_job
      job.options.hardware_acceleration_type = :vaapi
      job.options.rate_control = :crf
      args = described_class.encoder_args(job)
      expect(args).to include('-rc_mode', 'ICQ')
    ensure
      ENV.delete('JELLYFIN_VAAPI_DRIVER')
    end

    it 'falls back to CBR on AMD where ICQ is unavailable' do
      ENV['JELLYFIN_VAAPI_DRIVER'] = 'amd'
      job = hdr_job
      job.options.rate_control = :crf
      args = described_class.encoder_args(job)
      expect(args).to include('-rc_mode', 'CBR')
    ensure
      ENV.delete('JELLYFIN_VAAPI_DRIVER')
    end

    it 'inserts an OpenCL tonemap bridge for HDR input' do
      c = caps(filters: %w[tonemap_opencl], hwaccels: %w[vaapi])
      chain = described_class.filter_chain(hdr_job, c)
      expect(chain).to include('tonemap_opencl')
      expect(chain).to include('hwmap=derive_device=opencl')
    end

    it 'emits -bf only when driver is not i965' do
      ENV['JELLYFIN_VAAPI_DRIVER'] = 'i965'
      job = hdr_job
      expect(described_class.encoder_args(job)).not_to include('-bf')
    ensure
      ENV.delete('JELLYFIN_VAAPI_DRIVER')
    end
  end
end
