require 'spec_helper'

RSpec.describe Jellyfin::Rails::Configuration do
  subject(:config) { described_class.new }

  it 'defaults to looking up ffmpeg/ffprobe on PATH' do
    expect(config.ffmpeg_path).to eq('ffmpeg')
    expect(config.ffprobe_path).to eq('ffprobe')
  end

  it 'defaults to no allowed paths (deny-all)' do
    expect(config.allowed_paths).to eq([])
    expect(config.path_allowed?('/anything')).to be(false)
  end

  describe '#path_allowed?' do
    before { config.allowed_paths = ['/srv/media'] }

    it 'allows paths inside an allowed root' do
      expect(config.path_allowed?('/srv/media/movie.mkv')).to be(true)
      expect(config.path_allowed?('/srv/media/')).to be(true)
    end

    it 'allows the allowed root itself' do
      expect(config.path_allowed?('/srv/media')).to be(true)
    end

    it 'rejects sibling paths that share a prefix' do
      expect(config.path_allowed?('/srv/media-other/x.mkv')).to be(false)
    end

    it 'rejects paths outside any allowed root' do
      expect(config.path_allowed?('/etc/passwd')).to be(false)
    end

    it 'rejects blank input' do
      expect(config.path_allowed?(nil)).to be(false)
      expect(config.path_allowed?('')).to be(false)
    end
  end

  it 'is reset between examples via Jellyfin::Rails.reset_configuration!' do
    Jellyfin::Rails.configure { |c| c.hwaccel = :nvenc }
    expect(Jellyfin::Rails.configuration.hwaccel).to eq(:nvenc)
    Jellyfin::Rails.reset_configuration!
    expect(Jellyfin::Rails.configuration.hwaccel).to eq(:none)
  end
end
