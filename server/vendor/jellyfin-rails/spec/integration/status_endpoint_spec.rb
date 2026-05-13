require 'spec_helper'

RSpec.describe 'GET /jellyfin/_status', type: :request do
  it 'returns ffmpeg capabilities as JSON' do
    get '/jellyfin/_status'
    expect(response).to have_http_status(:ok)

    body = JSON.parse(response.body)
    expect(body).to include('gem_version', 'ffmpeg_path', 'ffmpeg')
    expect(body['gem_version']).to eq(Jellyfin::Rails::VERSION)

    ffmpeg = body['ffmpeg']
    expect(ffmpeg['version']).to match(/\A\d+\.\d+/)
    expect(ffmpeg['encoders']).to be_an(Array).and(include('aac'))
    expect(ffmpeg['filters']).to be_an(Array).and(include('scale'))
    expect(ffmpeg['hwaccels']).to be_an(Array)
  end
end
