require 'spec_helper'
require 'jellyfin/playback/playback_info'

RSpec.describe Jellyfin::Playback::PlaybackInfo do
  def mk_video(**ov)
    Jellyfin::Probing::MediaStream.new(
      index: 0, type: :video, codec: 'h264', profile: 'High', level: 41,
      width: 1920, height: 1080, frame_rate: 24.0, bit_rate: 4_000_000,
      pixel_format: 'yuv420p', sample_aspect_ratio: '1:1',
      field_order: 'progressive', is_interlaced: false,
      video_range: 'SDR', video_range_type: 'SDR', **ov
    )
  end

  def mk_audio(**ov)
    Jellyfin::Probing::MediaStream.new(
      index: 1, type: :audio, codec: 'aac', channels: 2, sample_rate: 48_000, **ov
    )
  end

  def mk_source(streams:, container: 'mp4')
    Jellyfin::Probing::MediaSourceInfo.new(
      id: 'x', path: '/srv/media/x.' + container, container: container,
      streams: streams, run_time_ticks: 600 * 10_000_000
    )
  end

  let(:browser) { Jellyfin::Playback::ClientProfile.modern_browser }
  let(:base_url) { 'http://example.test/_jellyfin' }
  let(:direct_token)    { 'tok_direct' }
  let(:transcode_token) { 'tok_transcode' }

  def info_for(media_source)
    described_class.for(
      media_source: media_source,
      profile: browser,
      base_url: base_url,
      token_for_direct: direct_token,
      token_for_transcode: transcode_token
    )
  end

  describe 'URL composition by decision mode' do
    context 'direct_play (source matches profile exactly)' do
      let(:src) { mk_source(streams: [mk_video, mk_audio], container: 'mp4') }
      it 'returns a direct_play_url, no transcoding_url' do
        info = info_for(src)
        expect(info.method).to eq(:direct_play)
        expect(info.direct_play_url).to eq("#{base_url}/stream/#{direct_token}")
        expect(info.transcoding_url).to be_nil
      end
    end

    # Regression for the original bug: direct_stream decisions used to
    # return BOTH urls = nil because PlaybackInfo only filled
    # transcoding_url when decision.transcode?. Upstream Jellyfin handles
    # DirectStream through the same HLS pipeline as Transcode (with -c
    # copy), so it needs a transcoding URL too. See MediaInfoHelper.cs:268.
    context 'direct_stream (container-only mismatch)' do
      let(:src) { mk_source(streams: [mk_video, mk_audio], container: 'mkv') }
      it 'returns a transcoding_url (NOT nil)' do
        info = info_for(src)
        expect(info.method).to eq(:direct_stream)
        expect(info.transcoding_url).to eq("#{base_url}/transcode/#{transcode_token}/master.m3u8")
        expect(info.transcoding_container).to eq('hls')
        expect(info.direct_play_url).to be_nil
      end
    end

    context 'transcode (codec mismatch)' do
      let(:src) { mk_source(streams: [mk_video(codec: 'hevc'), mk_audio], container: 'mkv') }
      it 'returns a transcoding_url, no direct_play_url' do
        info = info_for(src)
        expect(info.method).to eq(:transcode)
        expect(info.transcoding_url).to eq("#{base_url}/transcode/#{transcode_token}/master.m3u8")
        expect(info.transcoding_container).to eq('hls')
        expect(info.direct_play_url).to be_nil
      end
    end
  end
end
