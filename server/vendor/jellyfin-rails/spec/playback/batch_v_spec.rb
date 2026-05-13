require 'spec_helper'

RSpec.describe Jellyfin::Playback::MediaInfoHelper do
  describe '.get_max_bitrate (port of MediaInfoHelper.cs:495)' do
    it 'returns the client cap unchanged on a local-network IP' do
      cap = described_class.get_max_bitrate(
        client_max_bitrate: 5_000_000,
        remote_client_bitrate_limit: 2_000_000,
        ip_address: '192.168.1.10'
      )
      expect(cap).to eq(5_000_000)
    end

    it 'applies the remote limit when the client is on a public IP (upstream cs:510)' do
      cap = described_class.get_max_bitrate(
        client_max_bitrate: 10_000_000,
        remote_client_bitrate_limit: 3_000_000,
        ip_address: '203.0.113.5'
      )
      expect(cap).to eq(3_000_000)
    end

    it 'falls back to the remote limit when the client supplies none' do
      cap = described_class.get_max_bitrate(
        client_max_bitrate: nil,
        remote_client_bitrate_limit: 3_000_000,
        ip_address: '203.0.113.5'
      )
      expect(cap).to eq(3_000_000)
    end

    it 'leaves the client cap alone when no remote limit is configured' do
      cap = described_class.get_max_bitrate(
        client_max_bitrate: 10_000_000,
        remote_client_bitrate_limit: 0,
        ip_address: '203.0.113.5'
      )
      expect(cap).to eq(10_000_000)
    end
  end

  describe '.sort_media_sources (port of MediaInfoHelper.cs:354)' do
    let(:dp_local)     { instance_double('src', supports_direct_play: true, supports_direct_stream: false, protocol: 'file', bit_rate: 1_000_000) }
    let(:dp_http)      { instance_double('src', supports_direct_play: true, supports_direct_stream: false, protocol: 'http', bit_rate: 1_000_000) }
    let(:ds_local)     { instance_double('src', supports_direct_play: false, supports_direct_stream: true, protocol: 'file', bit_rate: 1_500_000) }
    let(:transcode_hi) { instance_double('src', supports_direct_play: false, supports_direct_stream: false, protocol: 'file', bit_rate: 10_000_000) }

    it 'puts file-protocol direct-play first (upstream cs:361)' do
      out = described_class.sort_media_sources([transcode_hi, dp_http, dp_local])
      expect(out.first).to equal(dp_local)
    end

    it 'puts direct-stream above plain transcode (upstream cs:371)' do
      out = described_class.sort_media_sources([transcode_hi, ds_local])
      expect(out.first).to equal(ds_local)
    end

    it 'penalises sources whose bitrate exceeds max_bitrate (upstream cs:388)' do
      out = described_class.sort_media_sources([transcode_hi, ds_local], max_bitrate: 5_000_000)
      expect(out.first).to equal(ds_local) # transcode_hi exceeds the cap
    end
  end
end

RSpec.describe Jellyfin::Playback::StreamState do
  let(:video) do
    Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264',
      width: 1920, height: 1080, frame_rate: 24.0, video_range_type: 'SDR',
      bit_rate: 4_000_000, profile: 'High', level: 41,
      pixel_format: 'yuv420p', sample_aspect_ratio: '1:1', is_interlaced: false)
  end

  let(:audio) do
    Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac', channels: 2, sample_rate: 48_000)
  end

  let(:source) do
    Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', container: 'mkv',
      streams: [video, audio], bit_rate: 5_000_000, run_time_ticks: 600_000_000)
  end

  it 'centralises request → job-info mapping (port of GetStreamingState)' do
    state = described_class.build(
      request: { video_codec: 'h264', audio_codec: 'aac',
                 video_bitrate: 3_000_000, audio_bitrate: 128_000,
                 audio_track: 0, video_track: 0, start_time_ticks: 100_000_000,
                 max_bitrate: 5_000_000, ip_address: '192.168.1.5',
                 auto_crop: true, multi_audio_tracks: true },
      media_source: source,
      profile: Jellyfin::Playback::ClientProfile.modern_browser
    )

    expect(state.video_stream).to equal(video)
    expect(state.audio_stream).to equal(audio)
    expect(state.output_video_codec).to eq('h264')
    expect(state.output_video_bitrate).to eq(3_000_000)
    expect(state.start_time_ticks).to eq(100_000_000)
    expect(state.options.auto_crop).to be(true)
    expect(state.options.multi_audio_tracks).to be(true)
    expect(state.max_bitrate).to eq(5_000_000) # local-network IP keeps client cap
    expect(state.decision).to be_a(Jellyfin::Playback::Decision::Result)
  end

  it 'segmented_live? mirrors EncodingJobInfo.IsSegmentedLiveStream' do
    live_source = Jellyfin::Probing::MediaSourceInfo.new(path: 'rtsp://x', streams: [video, audio], run_time_ticks: nil)
    state = described_class.build(request: {}, media_source: live_source)
    expect(state.segmented_live?).to be(true)

    vod_source = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: [video, audio], run_time_ticks: 600_000_000)
    state2 = described_class.build(request: {}, media_source: vod_source)
    expect(state2.segmented_live?).to be(false)
  end

  it 'infers codecs from container/extension when not supplied (upstream cs:155)' do
    state = described_class.build(request: {}, media_source: source)
    expect(state.output_video_codec).to eq('copy') # .mkv extension → copy
    expect(state.output_audio_codec).to eq('aac')  # mkv container → aac
  end

  it 'to_job_info produces a usable EncodingJobInfo' do
    state = described_class.build(request: { video_codec: 'h264', audio_codec: 'aac', max_height: 720 }, media_source: source)
    job = state.to_job_info
    expect(job).to be_a(Jellyfin::Encoding::EncodingJobInfo)
    expect(job.output_video_codec).to eq('h264')
    expect(job.output_height).to eq(720)
  end
end
