require 'spec_helper'

RSpec.describe Jellyfin::Encoding::AudioVbr do
  describe '.args_for libfdk_aac (upstream cs:2783)' do
    it 'maps per-channel <32k to -vbr:a 1' do
      expect(described_class.args_for(encoder: 'libfdk_aac', bitrate: 50_000, channels: 2)).to eq(['-vbr:a', '1'])
    end

    it 'maps per-channel >=96k to -vbr:a 5' do
      expect(described_class.args_for(encoder: 'libfdk_aac', bitrate: 200_000, channels: 2)).to eq(['-vbr:a', '5'])
    end

    it 'covers all 5 bands across 32k/48k/64k/96k boundaries' do
      grades = [50_000, 80_000, 110_000, 150_000, 200_000].map do |b|
        described_class.args_for(encoder: 'libfdk_aac', bitrate: b, channels: 2).last
      end
      expect(grades).to eq(%w[1 2 3 4 5])
    end
  end

  describe '.args_for libmp3lame (upstream cs:2795)' do
    it 'uses true-VBR -qscale:a when per-channel falls in the lame sweet spot' do
      args = described_class.args_for(encoder: 'libmp3lame', bitrate: 200_000, channels: 2) # 100k/ch
      expect(args).to eq(['-qscale:a', '2'])
    end

    it 'falls back to -abr:a 1 + -b:a for very low per-channel rates (upstream cs:2810)' do
      args = described_class.args_for(encoder: 'libmp3lame', bitrate: 48_000, channels: 2)
      expect(args).to include('-abr:a', '1')
      expect(args).to include('-b:a', '48000')
    end
  end

  describe '.args_for aac_at (upstream cs:2813)' do
    it 'emits Apple CVBR mode + bitrate' do
      args = described_class.args_for(encoder: 'aac_at', bitrate: 192_000, channels: 2)
      expect(args).to eq(['-aac_at_mode:a', '2', '-b:a', '192000'])
    end
  end

  describe '.args_for libvorbis (upstream cs:2819)' do
    it 'spans 5 quality bands by per-channel bitrate' do
      # 60k/2 = 30k → 0; 80k/2 = 40k → 2; 110k/2 = 55k → 2; 150k/2 = 75k → 4; 240k/2 = 120k → 8
      grades = [60_000, 80_000, 110_000, 150_000, 240_000].map do |b|
        described_class.args_for(encoder: 'libvorbis', bitrate: b, channels: 2).last
      end
      expect(grades).to eq(%w[0 2 2 4 8])
    end
  end

  describe '.args_for unknown encoder' do
    it 'returns nil so callers can fall back to -b:a' do
      expect(described_class.args_for(encoder: 'flac', bitrate: 192_000, channels: 2)).to be_nil
    end
  end
end

RSpec.describe Jellyfin::Encoding::ResolutionLimit do
  describe '.enforce! (upstream cs:2949)' do
    it 'moves width/height into max_width/max_height for a hash' do
      h = { width: 1280, height: 720 }
      out = described_class.enforce!(h)
      expect(out[:max_width]).to eq(1280)
      expect(out[:max_height]).to eq(720)
      expect(out[:width]).to be_nil
      expect(out[:height]).to be_nil
    end

    it 'preserves existing max_* when both are present' do
      h = { width: 1280, height: 720, max_width: 1920, max_height: 1080 }
      out = described_class.enforce!(h)
      expect(out[:max_width]).to eq(1920)
      expect(out[:max_height]).to eq(1080)
    end
  end
end

RSpec.describe Jellyfin::Encoding::TryStreamCopy do
  it 'sets output_video_codec=copy when StreamCopy.video? is eligible' do
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264',
      width: 1920, height: 1080, pixel_format: 'yuv420p', sample_aspect_ratio: '1:1',
      is_interlaced: false, video_range_type: 'SDR', bit_rate: 4_000_000)
    a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac', channels: 2, sample_rate: 48_000)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: [v, a])
    job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src,
      output_video_codec: 'h264', output_audio_codec: 'aac', output_video_bitrate: 5_000_000)

    described_class.call(job)
    expect(job.output_video_codec).to eq('copy')
    expect(job.output_audio_codec).to eq('copy')
  end

  it 'leaves video alone when StreamCopy.video? rejects (codec mismatch)' do
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'hevc',
      width: 1920, height: 1080, pixel_format: 'yuv420p', sample_aspect_ratio: '1:1',
      is_interlaced: false, video_range_type: 'SDR')
    a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac', channels: 2, sample_rate: 48_000)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: [v, a])
    job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src,
      output_video_codec: 'h264', output_audio_codec: 'aac')
    described_class.call(job)
    expect(job.output_video_codec).to eq('h264')
  end

  it 'force_copy=true overrides eligibility check (mirrors upstream user-permission branch)' do
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'hevc', width: 1920, height: 1080)
    a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac', channels: 2)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x', streams: [v, a])
    job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src,
      output_video_codec: 'h264', output_audio_codec: 'aac')
    described_class.call(job, force_copy: true)
    expect(job.output_video_codec).to eq('copy')
  end
end

RSpec.describe Jellyfin::Encoding::InputModifier do
  it 'includes -probesize / -analyzeduration' do
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264')
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: [v])
    job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, output_video_codec: 'h264')
    args = described_class.call(job: job)
    expect(args).to include('-probesize')
    expect(args).to include('-analyzeduration')
  end

  it 'adds -re for rtsp/rtmp/udp/srt/rtp inputs (upstream cs:7274)' do
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264')
    src = Jellyfin::Probing::MediaSourceInfo.new(path: 'rtsp://example/feed', streams: [v])
    job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, output_video_codec: 'h264')
    args = described_class.call(job: job)
    expect(args).to include('-re')
  end

  it 'adds -rtsp_transport for rtsp inputs (upstream cs:7257)' do
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264')
    src = Jellyfin::Probing::MediaSourceInfo.new(path: 'rtsp://example/feed', streams: [v])
    job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, output_video_codec: 'h264')
    args = described_class.call(job: job)
    expect(args).to include('-rtsp_transport', 'tcp+udp')
    expect(args).to include('-rtsp_flags', 'prefer_tcp')
  end
end

RSpec.describe Jellyfin::Encoding::AudioFilter do
  it 'returns nil when no audio filters apply' do
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264')
    a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac', channels: 2, sample_rate: 48_000)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x', streams: [v, a])
    job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src,
      output_video_codec: 'h264', output_audio_codec: 'aac', output_audio_channels: 2,
      output_audio_sample_rate: 48_000)
    expect(described_class.call(job)).to be_nil
  end

  it 'joins downmix + loudnorm into a comma-separated chain' do
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264')
    a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'eac3', channels: 6, sample_rate: 48_000)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x', streams: [v, a])
    opts = Jellyfin::Encoding::EncodingOptions.new
    opts.enable_loudnorm = true
    job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, options: opts,
      output_video_codec: 'h264', output_audio_codec: 'aac', output_audio_channels: 2,
      output_audio_sample_rate: 48_000)
    out = described_class.call(job)
    expect(out).to include('pan=stereo')
    expect(out).to include('loudnorm=')
  end
end

RSpec.describe Jellyfin::Encoding::QualityParam do
  let(:caps) do
    Class.new do
      def supports_encoder?(_) true end
      def supports_filter?(_) true end
      def supports_hwaccel?(_) false end
      def supports_decoder?(_) true end
    end.new
  end

  it 'dispatches to Quality.for for the given encoder' do
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264', width: 1920, height: 1080, bit_depth: 8)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x', streams: [v])
    job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, output_video_codec: 'h264')
    args = described_class.call(job: job, video_encoder: 'libx264', default_preset: 'medium')
    expect(args).to include('-preset', 'veryfast') # job options preset wins
    expect(args).to include('-profile:v', 'high')
  end

  it 'applies default_preset only when EncodingOptions has no preset' do
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264', width: 1920, height: 1080, bit_depth: 8)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x', streams: [v])
    opts = Jellyfin::Encoding::EncodingOptions.new
    opts.encoder_preset = ''
    job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, options: opts, output_video_codec: 'h264')
    args = described_class.call(job: job, video_encoder: 'libx264', default_preset: 'slow')
    expect(args).to include('-preset', 'slow')
  end
end
