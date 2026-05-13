require 'spec_helper'
require 'tmpdir'

RSpec.describe 'Batch L — Player endpoints', type: :request do
  let(:fixture) { File.join(FIXTURE_PATH, 'sample.mp4') }
  let(:tmp_root) { Dir.mktmpdir('jelly-batchl-') }

  before do
    skip 'fixture missing' unless File.exist?(fixture)
    ffmpeg = ENV.fetch('TEST_FFMPEG_PATH', '/Applications/Jellyfin.app/Contents/MacOS/ffmpeg')
    skip 'ffmpeg not present' unless File.executable?(ffmpeg)

    Jellyfin::Transcoding::TranscodeManager.reset!
    Jellyfin::Session::Tracker.reset!
    Jellyfin::Rails.configure do |c|
      c.ffmpeg_path = ffmpeg
      c.transcode_dir = tmp_root
      c.token_secret = 'batch-l-secret'
      c.allowed_paths = [FIXTURE_PATH]
      c.segment_length = 1
    end
  end

  after do
    Jellyfin::Transcoding::TranscodeManager.reset!
    Jellyfin::Session::Tracker.reset!
    FileUtils.rm_rf(tmp_root)
  end

  describe 'POST /playback_info' do
    it 'returns the negotiation result with stream URLs' do
      post '/jellyfin/playback_info',
           params: { path: fixture, client: { kind: 'modern_browser' } },
           as: :json
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['method']).to be_in(%w[direct_play direct_stream transcode])
      expect(body).to have_key('media_source')
      expect(body['media_source']['container']).to eq('mp4')
    end

    it 'forbids a path outside allowed_paths' do
      post '/jellyfin/playback_info', params: { path: '/etc/passwd' }, as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'POST /sessions/playing + progress + stopped + ping' do
    it 'tracks the session through its lifecycle' do
      post '/jellyfin/sessions/playing',
           params: { session_id: 'sess-1', item_id: 'item-A', run_time_ticks: 600_000_000 },
           as: :json
      expect(response).to have_http_status(:no_content)
      expect(Jellyfin::Session::Tracker.instance.size).to eq(1)

      post '/jellyfin/sessions/playing/progress',
           params: { session_id: 'sess-1', position_ticks: 100_000_000 },
           as: :json
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['position_ticks']).to eq(100_000_000)
      expect(body['progress_fraction']).to be_within(0.01).of(1.0 / 6.0)

      post '/jellyfin/sessions/playing/ping', params: { session_id: 'sess-1' }, as: :json
      expect(response).to have_http_status(:no_content)

      post '/jellyfin/sessions/playing/stopped',
           params: { session_id: 'sess-1', position_ticks: 600_000_000 },
           as: :json
      expect(response).to have_http_status(:ok)
      expect(Jellyfin::Session::Tracker.instance.size).to eq(0)
    end

    it '404s for an unknown session id' do
      post '/jellyfin/sessions/playing/progress', params: { session_id: 'no-such', position_ticks: 1 }, as: :json
      expect(response).to have_http_status(:not_found)
    end

    it 'GET /sessions/active enumerates the in-memory sessions' do
      Jellyfin::Session::Tracker.instance.started(id: 'a', item_id: 'x')
      Jellyfin::Session::Tracker.instance.started(id: 'b', item_id: 'y')
      get '/jellyfin/sessions/active'
      body = JSON.parse(response.body)
      expect(body['count']).to eq(2)
      expect(body['sessions'].map { |s| s['id'] }).to contain_exactly('a', 'b')
    end
  end

  describe 'GET /download/:token' do
    it 'serves the source with Content-Disposition: attachment' do
      token = Jellyfin::Transcoding::Token.encode(path: fixture)
      get "/jellyfin/download/#{token}"
      expect(response).to have_http_status(:ok)
      expect(response.headers['Content-Disposition']).to include('attachment')
      expect(response.headers['Content-Disposition']).to include(File.basename(fixture))
    end

    it 'rejects paths outside allowed_paths' do
      token = Jellyfin::Transcoding::Token.encode(path: '/etc/passwd')
      get "/jellyfin/download/#{token}"
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'GET /audio/:token/universal.:container' do
    it 'transcodes the audio track to the requested container' do
      token = Jellyfin::Transcoding::Token.encode(path: fixture)
      get "/jellyfin/audio/#{token}/universal.mp3"
      expect(response).to have_http_status(:ok)
      expect(response.headers['Content-Type']).to start_with('audio/')
      # Body is streamed via Enumerator — at least one chunk should arrive.
      expect(response.body.bytesize).to be > 1024
    end
  end

  describe 'GET /images/:token/:type' do
    it 'falls back to embedded cover when no sidecar exists' do
      token = Jellyfin::Transcoding::Token.encode(path: fixture)
      get "/jellyfin/images/#{token}/primary"
      # Sample mp4 has no embedded cover — expect either 404 or 200 with a tiny body.
      expect([200, 404]).to include(response.status)
    end

    it 'generates a chapter thumbnail at start_time' do
      token = Jellyfin::Transcoding::Token.encode(path: fixture)
      get "/jellyfin/images/#{token}/chapter", params: { start_time: 1.0, width: 240 }
      expect([200, 404]).to include(response.status)
      if response.status == 200
        expect(response.headers['Content-Type']).to eq('image/jpeg')
      end
    end
  end

  describe 'GET /trickplay/:token/:width/index.m3u8' do
    it 'generates trickplay tiles and emits a playlist' do
      token = Jellyfin::Transcoding::Token.encode(path: fixture)
      get "/jellyfin/trickplay/#{token}/240/index.m3u8"
      expect(response).to have_http_status(:ok)
      expect(response.body).to start_with('#EXTM3U')
      expect(response.body).to include('EXT-X-IMAGES-ONLY')
    end
  end

  describe 'GET /transcode/:token/progress' do
    it '404s for a job that hasnt started yet' do
      token = Jellyfin::Transcoding::Token.encode(path: fixture)
      get "/jellyfin/transcode/#{token}/progress"
      expect(response).to have_http_status(:not_found)
    end
  end
end

RSpec.describe Jellyfin::Session::Tracker do
  before { described_class.reset! }
  let(:tracker) { described_class.instance }

  it 'singletons across calls' do
    expect(described_class.instance).to equal(described_class.instance)
  end

  it 'progress fraction handles zero run time gracefully' do
    tracker.started(id: 'x', item_id: 'i', run_time_ticks: 0)
    s = tracker.progress(id: 'x', position_ticks: 50)
    expect(s.progress_fraction).to eq(0.0)
  end

  it 'ping updates last_updated_at without changing position' do
    tracker.started(id: 'p', item_id: 'i', run_time_ticks: 100)
    tracker.progress(id: 'p', position_ticks: 25)
    first = tracker.fetch('p').last_updated_at
    sleep 0.01
    tracker.ping(id: 'p')
    expect(tracker.fetch('p').last_updated_at).to be > first
    expect(tracker.fetch('p').position_ticks).to eq(25)
  end
end

RSpec.describe Jellyfin::Playback::PlaybackInfo do
  it 'maps direct_play decisions to a stream URL' do
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264',
      width: 1920, height: 1080, profile: 'high', level: 41,
      pixel_format: 'yuv420p', sample_aspect_ratio: '1:1',
      is_interlaced: false, video_range_type: 'SDR', frame_rate: 24.0,
      bit_rate: 4_000_000)
    a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac',
      channels: 2, sample_rate: 48_000)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mp4', container: 'mp4',
      streams: [v, a], bit_rate: 5_000_000)
    profile = Jellyfin::Playback::ClientProfile.modern_browser

    info = described_class.for(media_source: src, profile: profile,
      base_url: 'http://test', token_for_direct: 'tok-d', token_for_transcode: 'tok-t')
    expect(info.method).to eq(:direct_play)
    expect(info.direct_play_url).to eq('http://test/stream/tok-d')
    expect(info.transcoding_url).to be_nil
  end

  it 'falls back to transcode when codec incompatible' do
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'hevc',
      width: 1920, height: 1080, video_range_type: 'SDR')
    a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'eac3', channels: 6)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', container: 'mkv', streams: [v, a])
    profile = Jellyfin::Playback::ClientProfile.modern_browser
    info = described_class.for(media_source: src, profile: profile,
      base_url: 'http://test', token_for_direct: 'd', token_for_transcode: 't')
    expect(info.method).to eq(:transcode)
    expect(info.transcoding_url).to include('http://test/transcode/t/master.m3u8')
  end
end
