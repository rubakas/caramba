require 'spec_helper'

RSpec.describe Jellyfin::Transcoding::Token do
  before do
    Jellyfin::Rails.configure { |c| c.token_secret = 'test-secret' }
  end

  it 'roundtrips a payload' do
    payload = { path: '/srv/media/movie.mkv', video_bitrate: 2_000_000, audio_track: 1 }
    token = described_class.encode(payload)
    decoded = described_class.decode(token)
    expect(decoded[:path]).to eq('/srv/media/movie.mkv')
    expect(decoded[:video_bitrate]).to eq(2_000_000)
  end

  it 'includes a nonce so identical payloads produce distinct tokens' do
    t1 = described_class.encode(path: '/a.mkv')
    t2 = described_class.encode(path: '/a.mkv')
    expect(t1).not_to eq(t2)
  end

  it 'rejects a tampered token' do
    token = described_class.encode(path: '/srv/media/x.mkv')
    tampered = token.dup
    tampered[-3] = (tampered[-3] == 'A' ? 'B' : 'A')
    expect { described_class.decode(tampered) }.to raise_error(Jellyfin::Transcoding::Token::InvalidToken)
  end

  it 'rejects when signed with a different secret' do
    token = described_class.encode(path: '/srv/media/x.mkv')
    Jellyfin::Rails.configure { |c| c.token_secret = 'other-secret' }
    expect { described_class.decode(token) }.to raise_error(Jellyfin::Transcoding::Token::InvalidToken, /bad signature/)
  end

  it 'errors clearly when no secret is configured' do
    Jellyfin::Rails.configure { |c| c.token_secret = nil }
    expect { described_class.encode(path: '/a.mkv') }
      .to raise_error(Jellyfin::Transcoding::Token::InvalidToken, /not configured/)
  end
end
