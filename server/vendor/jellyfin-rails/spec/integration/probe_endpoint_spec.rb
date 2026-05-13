require 'spec_helper'

RSpec.describe 'GET /jellyfin/probe', type: :request do
  let(:fixture) { File.join(FIXTURE_PATH, 'sample.mp4') }

  before do
    skip 'fixture missing' unless File.exist?(fixture)
    Jellyfin::Rails.configure do |c|
      c.ffprobe_path = ENV.fetch('TEST_FFPROBE_PATH', '/Applications/Jellyfin.app/Contents/MacOS/ffprobe')
      c.allowed_paths = [FIXTURE_PATH]
    end
    skip 'ffprobe not present' unless File.executable?(Jellyfin::Rails.configuration.ffprobe_path)
  end

  it 'returns the probed MediaSourceInfo' do
    get '/jellyfin/probe', params: { path: fixture }
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body['container']).to eq('mp4')
    expect(body['streams'].size).to be >= 2
    expect(body['streams'].map { |s| s['codec'] }).to include('h264', 'aac')
  end

  it 'rejects a path outside allowed_paths' do
    get '/jellyfin/probe', params: { path: '/etc/passwd' }
    expect(response).to have_http_status(:forbidden)
  end

  it '404s a path inside allowed_paths that does not exist on disk' do
    get '/jellyfin/probe', params: { path: File.join(FIXTURE_PATH, 'does-not-exist.mkv') }
    expect(response).to have_http_status(:not_found)
  end
end
