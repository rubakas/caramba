require 'spec_helper'

RSpec.describe Jellyfin::PlayerHelper, type: :helper do
  let(:fixture) { File.join(FIXTURE_PATH, 'sample.mp4') }

  before do
    Jellyfin::Rails.configure do |c|
      c.token_secret = 'helper-test'
      c.allowed_paths = [FIXTURE_PATH]
    end
  end

  it 'renders a <jellyfin-player> element with a signed master.m3u8 URL' do
    html = helper.jellyfin_player(path: fixture, autoplay: true)
    expect(html).to match(/<jellyfin-player\b/)
    expect(html).to match(%r{src="/jellyfin/transcode/[^"]+/master\.m3u8"})
    expect(html).to include('autoplay')

    token = html[%r{transcode/([^/]+)/master\.m3u8}, 1]
    payload = Jellyfin::Transcoding::Token.decode(token)
    expect(payload[:path]).to eq(fixture)
  end

  it 'rejects paths outside allowed_paths' do
    expect { helper.jellyfin_player(path: '/etc/passwd') }
      .to raise_error(ArgumentError, /not allowed/)
  end

  it 'forwards transcode params into the signed token' do
    html = helper.jellyfin_player(path: fixture, video_bitrate: 2_500_000, max_height: 720)
    token = html[%r{transcode/([^/]+)/master\.m3u8}, 1]
    payload = Jellyfin::Transcoding::Token.decode(token)
    expect(payload[:video_bitrate]).to eq(2_500_000)
    expect(payload[:max_height]).to eq(720)
  end

  it 'sets reporter-url attribute when given' do
    html = helper.jellyfin_player(path: fixture, reporter_url: '/api/progress/42')
    expect(html).to include('reporter-url="/api/progress/42"')
  end
end
