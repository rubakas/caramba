require 'spec_helper'

# Regression: the direct-play endpoint must honour HTTP Range requests.
# Without 206 Partial Content the Android/Chromecast ExoPlayer downloaded
# the entire mkv on every seek (and on every initial play with a non-zero
# resume position), which produced multi-minute spinners and a player that
# always started from byte 0.
#
# Mirrors upstream's PhysicalFileResult.EnableRangeProcessing = true
# (FileStreamResponseHelpers.cs:109).
RSpec.describe 'GET /jellyfin/stream/:token Range support', type: :request do
  let(:fixture) { File.join(FIXTURE_PATH, 'sample.mp4') }
  let(:size)    { File.size(fixture) }
  let(:bytes)   { File.binread(fixture) }
  let(:token)   { Jellyfin::Transcoding::Token.encode(path: fixture) }

  before do
    skip 'fixture missing' unless File.exist?(fixture)
    Jellyfin::Rails.configure do |c|
      c.token_secret  = 'stream-range-spec'
      c.allowed_paths = [FIXTURE_PATH]
    end
  end

  it 'serves the whole file with 200 when no Range header is sent' do
    get "/jellyfin/stream/#{token}"
    expect(response).to have_http_status(:ok)
    expect(response.headers['Accept-Ranges']).to eq('bytes')
    expect(response.headers['Content-Length']).to eq(size.to_s)
    expect(response.body.bytesize).to eq(size)
    expect(response.body).to eq(bytes)
  end

  it 'returns 206 + Content-Range for a Range request' do
    get "/jellyfin/stream/#{token}", headers: { 'Range' => 'bytes=100-199' }
    expect(response).to have_http_status(:partial_content)
    expect(response.headers['Content-Range']).to eq("bytes 100-199/#{size}")
    expect(response.headers['Content-Length']).to eq('100')
    expect(response.body.bytesize).to eq(100)
    expect(response.body).to eq(bytes[100..199])
  end

  it 'handles the open-ended N- range that ExoPlayer issues mid-stream' do
    offset = size / 2
    get "/jellyfin/stream/#{token}", headers: { 'Range' => "bytes=#{offset}-" }
    expect(response).to have_http_status(:partial_content)
    expect(response.headers['Content-Range']).to eq("bytes #{offset}-#{size - 1}/#{size}")
    expect(response.headers['Content-Length']).to eq((size - offset).to_s)
    expect(response.body).to eq(bytes[offset..])
  end

  it 'handles suffix-range -N (last N bytes — what fMP4 init readers use)' do
    get "/jellyfin/stream/#{token}", headers: { 'Range' => 'bytes=-256' }
    expect(response).to have_http_status(:partial_content)
    expect(response.headers['Content-Range']).to eq("bytes #{size - 256}-#{size - 1}/#{size}")
    expect(response.headers['Content-Length']).to eq('256')
    expect(response.body).to eq(bytes[-256..])
  end

  it 'clamps an over-long last byte to file_size - 1' do
    get "/jellyfin/stream/#{token}", headers: { 'Range' => "bytes=0-#{size + 1_000_000}" }
    expect(response).to have_http_status(:partial_content)
    expect(response.headers['Content-Range']).to eq("bytes 0-#{size - 1}/#{size}")
    expect(response.headers['Content-Length']).to eq(size.to_s)
  end

  it 'returns 416 + Content-Range: bytes */N for an unsatisfiable Range' do
    get "/jellyfin/stream/#{token}", headers: { 'Range' => "bytes=#{size + 100}-" }
    expect(response).to have_http_status(416)
    expect(response.headers['Content-Range']).to eq("bytes */#{size}")
  end

  it 'returns 416 for a malformed Range header' do
    get "/jellyfin/stream/#{token}", headers: { 'Range' => 'pages=1-2' }
    expect(response).to have_http_status(416)
  end

  it 'HEAD returns the same headers as GET but no body' do
    head "/jellyfin/stream/#{token}"
    expect(response).to have_http_status(:ok)
    expect(response.headers['Accept-Ranges']).to eq('bytes')
    expect(response.headers['Content-Length']).to eq(size.to_s)
    expect(response.body).to be_empty
  end

  it 'HEAD with Range returns 206 headers + no body' do
    head "/jellyfin/stream/#{token}", headers: { 'Range' => 'bytes=0-1023' }
    expect(response).to have_http_status(:partial_content)
    expect(response.headers['Content-Range']).to eq("bytes 0-1023/#{size}")
    expect(response.headers['Content-Length']).to eq('1024')
    expect(response.body).to be_empty
  end
end
