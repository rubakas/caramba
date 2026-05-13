require 'spec_helper'
require 'tmpdir'

RSpec.describe 'GET /jellyfin/subtitles/:token/:index.:format', type: :request do
  let(:fixture) { File.join(FIXTURE_PATH, 'sample.mp4') }
  let(:tmp_root) { Dir.mktmpdir('jelly-subs-') }

  before do
    skip 'fixture missing' unless File.exist?(fixture)
    Jellyfin::Rails.configure do |c|
      c.ffmpeg_path = ENV.fetch('TEST_FFMPEG_PATH', '/Applications/Jellyfin.app/Contents/MacOS/ffmpeg')
      c.transcode_dir = tmp_root
      c.token_secret = 'subs-secret'
      c.allowed_paths = [FIXTURE_PATH]
    end
    skip 'ffmpeg not present' unless File.executable?(Jellyfin::Rails.configuration.ffmpeg_path)
  end

  after { FileUtils.rm_rf(tmp_root) }

  it 'rejects bad tokens' do
    get '/jellyfin/subtitles/garbage/0.vtt'
    expect(response).to have_http_status(:bad_request)
  end

  it 'rejects unsupported formats via the route constraint' do
    token = Jellyfin::Transcoding::Token.encode(path: fixture)
    expect { get "/jellyfin/subtitles/#{token}/0.xyz" }.to raise_error(ActionController::RoutingError)
  end

  it 'returns 5xx (or appropriate error) when source has no subtitle stream at that index' do
    # sample.mp4 has no subtitle streams — extraction must surface as a 5xx
    # rather than a successful 0-byte file.
    token = Jellyfin::Transcoding::Token.encode(path: fixture)
    expect { get "/jellyfin/subtitles/#{token}/0.vtt" }.to raise_error(/subtitle extract failed/)
  end
end
