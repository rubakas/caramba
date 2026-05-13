require 'spec_helper'

RSpec.describe Jellyfin::Transcoding::ArgsBuilder do
  let(:params) { { path: '/srv/media/x.mp4', video_bitrate: 3_000_000, max_height: 720, segment_length: 4 } }
  subject(:args) { described_class.new(params).call(playlist_path: '/tmp/out.m3u8', segment_template: '/tmp/%d.ts') }

  it 'includes the input path' do
    expect(args).to include('-i', '/srv/media/x.mp4')
  end

  it 'forces h264 with consistent keyframes for HLS' do
    expect(args).to include('-c:v', 'libx264')
    expect(args).to include('-g', '96') # 4s * 24fps default approximation
    expect(args).to include('-sc_threshold', '0')
  end

  it 'forces aac stereo audio' do
    expect(args).to include('-c:a', 'aac', '-ac', '2')
  end

  it 'applies max_height scale when specified' do
    expect(args.join(' ')).to include("scale=-2:'min(720,ih)'")
  end

  it 'outputs HLS with the requested segment length and event playlist' do
    expect(args).to include('-f', 'hls')
    expect(args).to include('-hls_time', '4')
    expect(args).to include('-hls_playlist_type', 'event')
    expect(args.last).to eq('/tmp/out.m3u8')
  end
end
