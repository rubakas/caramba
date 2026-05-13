require 'spec_helper'
require 'tmpdir'

RSpec.describe 'transcoding endpoints', type: :request do
  let(:fixture) { File.join(FIXTURE_PATH, 'sample.mp4') }
  let(:tmp_root) { Dir.mktmpdir('jelly-it-') }

  before do
    skip 'fixture missing' unless File.exist?(fixture)
    ffmpeg = ENV.fetch('TEST_FFMPEG_PATH', '/Applications/Jellyfin.app/Contents/MacOS/ffmpeg')
    skip 'ffmpeg not present' unless File.executable?(ffmpeg)

    Jellyfin::Transcoding::TranscodeManager.reset!
    Jellyfin::Rails.configure do |c|
      c.ffmpeg_path = ffmpeg
      c.transcode_dir = tmp_root
      c.token_secret = 'integration-test-secret'
      c.allowed_paths = [FIXTURE_PATH]
      c.segment_length = 1
    end
  end

  after do
    Jellyfin::Transcoding::TranscodeManager.reset!
    FileUtils.rm_rf(tmp_root)
  end

  it 'POST /transcode/start → token → GET master.m3u8 → segment.ts (full loop)' do
    post '/jellyfin/transcode/start', params: { path: fixture, video_bitrate: 500_000, segment_length: 1 }
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    token = body['token']
    expect(token).to be_a(String).and(satisfy { |t| t.length > 16 })

    get "/jellyfin/transcode/#{token}/master.m3u8"
    expect(response).to have_http_status(:ok)
    expect(response.content_type).to start_with('application/vnd.apple.mpegurl')
    expect(response.body).to include('#EXTM3U')

    get "/jellyfin/transcode/#{token}/0.ts"
    expect(response).to have_http_status(:ok)
    expect(response.content_type).to start_with('video/mp2t')
    expect(response.body.bytesize).to be > 1_000
  end

  it 'rejects start for a path outside allowed_paths' do
    post '/jellyfin/transcode/start', params: { path: '/etc/passwd' }
    expect(response).to have_http_status(:forbidden)
  end

  it 'rejects a bad token on master.m3u8' do
    get '/jellyfin/transcode/not-a-real-token/master.m3u8'
    expect(response).to have_http_status(:bad_request)
  end
end
