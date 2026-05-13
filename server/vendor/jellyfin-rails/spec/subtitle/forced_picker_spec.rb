require 'spec_helper'

RSpec.describe Jellyfin::Subtitle::ForcedPicker do
  def sub(idx:, lang:, forced:)
    Jellyfin::Probing::MediaStream.new(index: idx, type: :subtitle, codec: 'subrip',
      language: lang, is_forced: forced)
  end

  it 'returns nil for empty input' do
    expect(described_class.choose(nil)).to be_nil
    expect(described_class.choose([])).to be_nil
  end

  it 'prefers a forced track whose language matches the audio track' do
    streams = [
      sub(idx: 0, lang: 'eng', forced: false),
      sub(idx: 1, lang: 'eng', forced: true),
      sub(idx: 2, lang: 'jpn', forced: true)
    ]
    pick = described_class.choose(streams, audio_lang: 'eng')
    expect(pick.index).to eq(1)
  end

  it 'falls back to any forced track when language match is missing' do
    streams = [
      sub(idx: 0, lang: 'eng', forced: false),
      sub(idx: 1, lang: 'jpn', forced: true)
    ]
    expect(described_class.choose(streams, audio_lang: 'fra').index).to eq(1)
  end

  it 'returns nil when no track is forced' do
    streams = [
      sub(idx: 0, lang: 'eng', forced: false),
      sub(idx: 1, lang: 'eng', forced: false)
    ]
    expect(described_class.choose(streams, audio_lang: 'eng')).to be_nil
  end
end
