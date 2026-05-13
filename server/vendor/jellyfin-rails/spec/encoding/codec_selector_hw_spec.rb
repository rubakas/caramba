require 'spec_helper'

RSpec.describe Jellyfin::Encoding::CodecSelector do
  def caps(*supported)
    obj = Object.new
    encoders = supported.flatten
    obj.define_singleton_method(:supports_encoder?) { |n| encoders.include?(n) }
    obj
  end

  describe '.video_encoder_for with hw_type' do
    it 'picks h264_videotoolbox on macOS when ffmpeg has it compiled in' do
      enc = described_class.video_encoder_for('h264', caps('h264_videotoolbox', 'libx264'),
                                              hw_type: :videotoolbox)
      expect(enc).to eq('h264_videotoolbox')
    end

    it 'picks hevc_nvenc on NVIDIA hosts' do
      enc = described_class.video_encoder_for('h265', caps('hevc_nvenc', 'libx265'),
                                              hw_type: :nvenc)
      expect(enc).to eq('hevc_nvenc')
    end

    it 'falls through to software when HW encoder is absent' do
      enc = described_class.video_encoder_for('h264', caps('libx264'), hw_type: :nvenc)
      expect(enc).to eq('libx264')
    end

    it 'falls through to software when no hw_type is given' do
      enc = described_class.video_encoder_for('h264', caps('libx264', 'h264_nvenc'))
      expect(enc).to eq('libx264')
    end

    it 'honors `copy` regardless of hw_type' do
      expect(described_class.video_encoder_for('copy', caps, hw_type: :qsv)).to eq('copy')
    end

    it 'picks av1_qsv for AV1 on Intel Arc hosts' do
      enc = described_class.video_encoder_for('av1', caps('av1_qsv', 'libsvtav1'),
                                              hw_type: :qsv)
      expect(enc).to eq('av1_qsv')
    end

    it 'returns first software candidate when neither HW nor any candidate is supported' do
      enc = described_class.video_encoder_for('h264', caps, hw_type: :vaapi)
      expect(enc).to eq('libx264')
    end
  end
end
