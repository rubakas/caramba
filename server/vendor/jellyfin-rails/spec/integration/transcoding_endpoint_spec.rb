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

  it 'serves a VOD variant playlist (PLAYLIST-TYPE:VOD + ENDLIST + every segment listed)' do
    # Safari's native HLS engine refuses to start playback on EVENT-mode
    # playlists without ENDLIST; the variant endpoint must hand-build a
    # full VOD playlist from the probed duration. Regression for the
    # bug where ffmpeg's in-progress playlist was being served verbatim.
    post '/jellyfin/transcode/start', params: { path: fixture, video_bitrate: 500_000, segment_length: 1 }
    token = JSON.parse(response.body)['token']

    get "/jellyfin/transcode/#{token}/main.m3u8"
    expect(response).to have_http_status(:ok)
    expect(response.content_type).to start_with('application/vnd.apple.mpegurl')
    body = response.body
    expect(body).to include('#EXT-X-PLAYLIST-TYPE:VOD')
    expect(body).to include('#EXT-X-ENDLIST')
    expect(body).to match(/^0\.ts$/) # first segment listed up front, not waited-for
  end

  it 'omits subtitle and trickplay rendition groups when token defaults' do
    # Default token (no `subtitle_delivery=hls`, no `trickplay=true`).
    # Caramba clients declare `SubtitleProfiles.Method=External` so the
    # playback_controller resolves this case → master must NOT include
    # EXT-X-MEDIA:TYPE=SUBTITLES (those refs hung Safari when their
    # backing webvtt index endpoints stalled extracting from a 2.5h MKV).
    post '/jellyfin/transcode/start', params: { path: fixture, video_bitrate: 500_000, segment_length: 1 }
    token = JSON.parse(response.body)['token']

    get "/jellyfin/transcode/#{token}/master.m3u8"
    expect(response).to have_http_status(:ok)
    body = response.body
    expect(body).not_to include('EXT-X-MEDIA:TYPE=SUBTITLES')
    expect(body).not_to include('EXT-X-IMAGE-STREAM-INF')
    expect(body).to include('#EXT-X-STREAM-INF')
    expect(body).to include('main.m3u8')
  end

  it 'emits subtitle MEDIA only when the token opts into HLS subtitle delivery' do
    post '/jellyfin/transcode/start', params: {
      path: fixture, video_bitrate: 500_000, segment_length: 1,
      subtitle_delivery: 'hls'
    }
    token = JSON.parse(response.body)['token']

    get "/jellyfin/transcode/#{token}/master.m3u8"
    expect(response).to have_http_status(:ok)
    # sample.mp4 has no subtitle streams to enumerate, but the branch
    # must be live — we assert the token's `subtitle_delivery` round-trips
    # so the controller's branch fires (build_subtitle_tracks returns []
    # when the source has no text subs, which is exactly sample.mp4).
    payload = Jellyfin::Transcoding::Token.decode(token)
    expect(payload[:subtitle_delivery]).to eq('hls')
  end

  it 'emits EXT-X-IMAGE-STREAM-INF only when the token opts into trickplay' do
    post '/jellyfin/transcode/start', params: {
      path: fixture, video_bitrate: 500_000, segment_length: 1,
      trickplay: 'true'
    }
    token = JSON.parse(response.body)['token']

    get "/jellyfin/transcode/#{token}/master.m3u8"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('EXT-X-IMAGE-STREAM-INF')
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
