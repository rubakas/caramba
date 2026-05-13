require 'spec_helper'

RSpec.describe Jellyfin::Encoding::Hwaccel do
  def caps_for(encoders:, filters: [], hwaccels: [])
    encoders = encoders.dup
    filters = filters.dup
    hwaccels = hwaccels.dup
    Struct.new(:encoders, :filters, :hwaccels).new(encoders, filters, hwaccels).tap do |c|
      def c.supports_encoder?(n); encoders.include?(n); end
      def c.supports_filter?(n);  filters.include?(n);  end
      def c.supports_hwaccel?(n); hwaccels.include?(n); end
    end
  end

  describe '.autodetect' do
    it 'picks VideoToolbox when available' do
      c = caps_for(encoders: ['h264_videotoolbox'], hwaccels: ['videotoolbox'])
      expect(described_class.autodetect(c)).to eq(Jellyfin::Encoding::Hwaccel::Videotoolbox)
    end

    it 'picks VAAPI when available and VideoToolbox is not' do
      c = caps_for(encoders: ['h264_vaapi'], hwaccels: ['vaapi'])
      expect(described_class.autodetect(c)).to eq(Jellyfin::Encoding::Hwaccel::Vaapi)
    end

    it 'returns nil when nothing is available' do
      c = caps_for(encoders: ['libx264'])
      expect(described_class.autodetect(c)).to be_nil
    end
  end

  describe Jellyfin::Encoding::Hwaccel::Videotoolbox do
    let(:caps) do
      caps_for(
        encoders: %w[h264_videotoolbox hevc_videotoolbox],
        filters:  %w[tonemap_videotoolbox],
        hwaccels: %w[videotoolbox]
      )
    end

    it 'selects h264_videotoolbox for H.264 targets' do
      expect(described_class.encoder_for('h264', caps)).to eq('h264_videotoolbox')
    end

    it 'emits -hwaccel videotoolbox + -hwaccel_output_format videotoolbox_vld in decode args' do
      # Regression: without -hwaccel_output_format, the decoder downloads
      # frames to system memory and tonemap_videotoolbox (which wants HW
      # frames on CVPixelBuffer) fails:
      #   Impossible to convert between the formats supported by the
      #   filter 'graph -1 input' and 'auto_scale_0'
      job = make_job
      expect(described_class.decode_args(job, caps)).to eq(
        ['-hwaccel', 'videotoolbox', '-hwaccel_output_format', 'videotoolbox_vld']
      )
    end

    it 'emits a tonemap_videotoolbox filter for HDR input' do
      job = make_job(hdr: true)
      chain = described_class.filter_chain(job, caps)
      expect(chain).to include('tonemap_videotoolbox=tonemap=bt2390')
    end

    def make_job(hdr: false)
      v = Jellyfin::Probing::MediaStream.new(
        index: 0, type: :video, codec: hdr ? 'hevc' : 'h264',
        width: 3840, height: 2160, frame_rate: 24.0,
        video_range: hdr ? 'HDR' : 'SDR',
        video_range_type: hdr ? 'HDR10' : 'SDR'
      )
      source = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: [v])
      Jellyfin::Encoding::EncodingJobInfo.new(media_source: source)
    end
  end

  describe Jellyfin::Encoding::EncodingHelper, 'with HW accel' do
    it 'uses h264_videotoolbox when HW accel is enabled and available' do
      caps = Class.new do
        def supports_encoder?(name); %w[libx264 h264_videotoolbox aac].include?(name); end
        def supports_filter?(name);  %w[scale tonemap_videotoolbox].include?(name); end
        def supports_hwaccel?(name); name == 'videotoolbox'; end
        def supports_decoder?(_);    true; end
      end.new
      options = Jellyfin::Encoding::EncodingOptions.new
      options.enable_hardware_encoding = true
      options.hardware_acceleration_type = :videotoolbox
      source = Jellyfin::Probing::MediaSourceInfo.new(
        path: '/x.mkv',
        streams: [
          Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264', width: 1920, height: 1080, frame_rate: 24.0, video_range: 'SDR', video_range_type: 'SDR'),
          Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac', channels: 2, sample_rate: 48_000)
        ]
      )
      job = Jellyfin::Encoding::EncodingJobInfo.new(
        media_source: source, options: options, output_video_codec: 'h264'
      )
      args = described_class.command_line_arguments(
        job, playlist_path: '/tmp/o.m3u8', segment_template: '/tmp/%d.ts', capabilities: caps
      )
      expect(args).to include('-c:v', 'h264_videotoolbox')
      expect(args).to include('-hwaccel', 'videotoolbox')
    end
  end
end
