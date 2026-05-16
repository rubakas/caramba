require 'spec_helper'

RSpec.describe Jellyfin::Encoding::Seek do
  def make_job(start_seconds: 0, video_codec: 'h264', output_video_codec: 'h264',
               burn: false, hdr: false, tonemap: true, force_accurate: false)
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: video_codec,
      width: 1920, height: 1080, video_range_type: hdr ? 'HDR10' : 'SDR')
    a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac', channels: 2, sample_rate: 48_000)
    streams = [v, a]
    sub = nil
    if burn
      sub = Jellyfin::Probing::MediaStream.new(index: 2, type: :subtitle, codec: 'subrip')
      streams << sub
    end
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: streams)
    opts = Jellyfin::Encoding::EncodingOptions.new
    opts.enable_tonemapping = tonemap
    opts.force_accurate_seek = force_accurate
    Jellyfin::Encoding::EncodingJobInfo.new(
      media_source: src,
      options: opts,
      output_video_codec: output_video_codec,
      start_time_ticks: (start_seconds * 10_000_000).to_i,
      subtitle_method: burn ? :encode : :soft,
      subtitle_stream: sub
    )
  end

  describe '.plan_for' do
    it 'is empty when start_time_ticks is zero' do
      plan = described_class.plan_for(make_job(start_seconds: 0))
      expect(plan).to be_empty
    end

    it 'uses pre-input fast seek when transcoding without subs or tonemap' do
      plan = described_class.plan_for(make_job(start_seconds: 30))
      expect(plan.pre_input).to eq(['-ss', '30.000'])
      expect(plan.post_input).to eq([])
    end

    it 'stays on pre-input fast seek when burning subtitles' do
      # Burn-in does NOT justify accurate seek. The old behaviour (post-
      # input `-ss`) made every bitmap-sub resume decode-from-zero up to
      # the seek point, taking minutes on long sources and timing out
      # the client (verified 2026-05-16 on The Iron Giant: resume at
      # source-time 2028 s never produced an init segment within 30 s).
      # The PgsOverlay filter aligns by source-time PTS, so landing on
      # the keyframe ≤ target via fast seek is fine; hls.js bridges the
      # few seconds between keyframe and target via SourceBuffer
      # timestampOffset.
      plan = described_class.plan_for(make_job(start_seconds: 30, burn: true))
      expect(plan.pre_input).to eq(['-ss', '30.000'])
      expect(plan.post_input).to eq([])
    end

    it 'stays on pre-input fast seek for HDR with tonemapping' do
      # HDR tonemap is frame-local — landing on the keyframe ≤ target is
      # fine and hls.js bridges the slack via SourceBuffer.timestampOffset.
      # The old `return true if hdr_input? && tonemap` made every resume
      # on an HDR source decode-from-zero, e.g. The Devil Wears Prada at
      # source-time 678 s timed out before any output appeared (verified
      # 2026-05-16). Accurate seek stays available via the explicit
      # `force_accurate_seek` option for non-HLS outputs.
      plan = described_class.plan_for(make_job(start_seconds: 30, hdr: true, tonemap: true))
      expect(plan.pre_input).to eq(['-ss', '30.000'])
      expect(plan.post_input).to eq([])
    end

    it 'uses fast seek for stream-copy regardless of options' do
      plan = described_class.plan_for(make_job(start_seconds: 30, output_video_codec: 'copy'))
      expect(plan.pre_input).to eq(['-ss', '30.000'])
      expect(plan.post_input).to eq([])
    end

    it 'respects force_accurate_seek override' do
      plan = described_class.plan_for(make_job(start_seconds: 30, force_accurate: true))
      expect(plan.post_input).to eq(['-ss', '30.000'])
    end

    it 'records the start segment for downstream segment numbering' do
      plan = described_class.plan_for(make_job(start_seconds: 30), start_segment: 5)
      expect(plan.start_segment).to eq(5)
    end
  end

  describe '.hls_segment_number_args' do
    it 'is empty when start_segment is 0' do
      expect(described_class.hls_segment_number_args(0)).to eq([])
    end

    it 'emits -start_number when start_segment > 0' do
      expect(described_class.hls_segment_number_args(7)).to eq(['-start_number', '7'])
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

  it 'places fast seek BEFORE -i and emits no -start_number when start_segment is 0' do
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264', width: 1920, height: 1080)
    a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac', channels: 2, sample_rate: 48_000)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: [v, a])
    job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src,
      output_video_codec: 'h264', output_audio_codec: 'aac',
      start_time_ticks: 300_000_000) # 30s

    args = described_class.command_line_arguments(
      job, playlist_path: '/tmp/p.m3u8', segment_template: '/tmp/%d.ts', capabilities: caps
    )
    ss_idx = args.index('-ss')
    i_idx  = args.index('-i')
    expect(ss_idx).to be < i_idx
    expect(args).not_to include('-start_number')
  end

  it 'emits -start_number N when start_segment > 0' do
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264', width: 1920, height: 1080)
    a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac', channels: 2, sample_rate: 48_000)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: [v, a])
    job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src,
      output_video_codec: 'h264', output_audio_codec: 'aac',
      start_time_ticks: 600_000_000)

    args = described_class.command_line_arguments(
      job, playlist_path: '/tmp/p.m3u8', segment_template: '/tmp/%d.ts',
      capabilities: caps, start_segment: 10
    )
    sn_idx = args.index('-start_number')
    expect(sn_idx).not_to be_nil
    expect(args[sn_idx + 1]).to eq('10')
  end
end
