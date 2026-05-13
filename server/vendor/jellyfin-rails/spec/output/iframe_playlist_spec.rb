require 'spec_helper'

RSpec.describe Jellyfin::Output::IframePlaylist do
  it 'adds i_frames_only flag and a sidecar playlist path' do
    args = described_class.output_args(iframe_playlist_path: '/tmp/iframes.m3u8')
    expect(args).to include('-hls_flags', 'i_frames_only')
    expect(args).to include('-hls_iframe_playlist', '/tmp/iframes.m3u8')
  end
end
