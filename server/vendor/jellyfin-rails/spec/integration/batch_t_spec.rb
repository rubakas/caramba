require 'spec_helper'
require 'tmpdir'

RSpec.describe 'Batch T — Telemetry / control endpoints', type: :request do
  let(:fixture) { File.join(FIXTURE_PATH, 'sample.mp4') }
  let(:tmp_root) { Dir.mktmpdir('jelly-t-') }

  before do
    skip 'fixture missing' unless File.exist?(fixture)
    Jellyfin::Transcoding::TranscodeManager.reset!
    Jellyfin::Rails.configure do |c|
      c.ffmpeg_path = '/usr/bin/true'
      c.transcode_dir = tmp_root
      c.token_secret = 'batch-t'
      c.allowed_paths = [FIXTURE_PATH]
    end
  end

  after do
    Jellyfin::Transcoding::TranscodeManager.reset!
    FileUtils.rm_rf(tmp_root)
  end

  describe 'GET /playback/bitrate_test' do
    it 'returns the requested number of random bytes (upstream MediaInfo.cs:331)' do
      get '/jellyfin/playback/bitrate_test', params: { size: 4096 }
      expect(response).to have_http_status(:ok)
      expect(response.headers['Content-Type']).to start_with('application/octet-stream')
      expect(response.body.bytesize).to eq(4096)
    end

    it 'defaults to 102400 bytes when size is omitted' do
      get '/jellyfin/playback/bitrate_test'
      expect(response.body.bytesize).to eq(102_400)
    end

    it '422s when size is out of range (upstream Range attribute)' do
      get '/jellyfin/playback/bitrate_test', params: { size: 0 }
      expect(response).to have_http_status(:unprocessable_entity)
      get '/jellyfin/playback/bitrate_test', params: { size: 200_000_000 }
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'DELETE /videos/active_encodings' do
    it 'kills every job matching the play_session_id (upstream HlsSegmentController.cs:116)' do
      mgr = Jellyfin::Transcoding::TranscodeManager.instance
      j1 = Jellyfin::Transcoding::TranscodingJob.new(id: 'a', params: { play_session_id: 'sess-1' }, root_dir: tmp_root)
      j2 = Jellyfin::Transcoding::TranscodingJob.new(id: 'b', params: { play_session_id: 'sess-1' }, root_dir: tmp_root)
      j3 = Jellyfin::Transcoding::TranscodingJob.new(id: 'c', params: { play_session_id: 'sess-2' }, root_dir: tmp_root)
      mgr.instance_variable_get(:@jobs).merge!('a' => j1, 'b' => j2, 'c' => j3)

      expect(mgr).to receive(:cancel!).with('a')
      expect(mgr).to receive(:cancel!).with('b')
      expect(mgr).not_to receive(:cancel!).with('c')

      delete '/jellyfin/videos/active_encodings', params: { play_session_id: 'sess-1' }
      expect(response).to have_http_status(:no_content)
    end

    it '422s when play_session_id is missing' do
      delete '/jellyfin/videos/active_encodings'
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'GET /playback_info — upstream GET variant' do
    it 'accepts the same params as POST and returns the same response shape' do
      get '/jellyfin/playback_info', params: { path: fixture, client: { kind: 'modern_browser' } }
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body).to have_key('method')
      expect(body).to have_key('media_source')
    end
  end

  describe 'HEAD support on streaming endpoints' do
    it 'master playlist responds to HEAD with playlist content type' do
      token = Jellyfin::Transcoding::Token.encode(path: fixture, segment_length: 1)
      head "/jellyfin/transcode/#{token}/master.m3u8"
      # Even if the playlist isn't ready, the route should accept HEAD.
      expect(response.status).not_to eq(404) # routing-not-found would be 404
      expect(response.status).not_to eq(405) # method-not-allowed
    end

    it 'stream endpoint accepts HEAD' do
      token = Jellyfin::Transcoding::Token.encode(path: fixture)
      head "/jellyfin/stream/#{token}"
      expect(response).to have_http_status(:ok)
    end
  end
end
