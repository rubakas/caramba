require 'spec_helper'

RSpec.describe Jellyfin::Playback::Decision do
  def mk_video(**ov)
    Jellyfin::Probing::MediaStream.new(
      index: 0, type: :video, codec: 'h264', profile: 'High', level: 41,
      width: 1920, height: 1080, frame_rate: 24.0, bit_rate: 4_000_000,
      pixel_format: 'yuv420p', sample_aspect_ratio: '1:1',
      field_order: 'progressive', is_interlaced: false,
      video_range: 'SDR', video_range_type: 'SDR', **ov
    )
  end

  def mk_audio(**ov)
    Jellyfin::Probing::MediaStream.new(
      index: 1, type: :audio, codec: 'aac', channels: 2, sample_rate: 48_000, **ov
    )
  end

  def mk_source(streams:, container: 'mp4')
    Jellyfin::Probing::MediaSourceInfo.new(
      path: '/srv/media/x.' + container, container: container, streams: streams,
      run_time_ticks: 600 * 10_000_000
    )
  end

  let(:browser) { Jellyfin::Playback::ClientProfile.modern_browser }

  describe 'direct play eligibility' do
    it 'picks :direct_play when source matches client profile exactly' do
      src = mk_source(streams: [mk_video, mk_audio], container: 'mp4')
      result = described_class.call(media_source: src, profile: browser)
      expect(result.mode).to eq(:direct_play)
      expect(result.container).to eq('mp4')
    end

    it 'demotes to :direct_stream when container is incompatible (mkv → browser only takes mp4)' do
      src = mk_source(streams: [mk_video, mk_audio], container: 'mkv')
      result = described_class.call(media_source: src, profile: browser)
      expect(result.mode).to eq(:direct_stream)
      expect(result.container).to eq('mp4')
      expect(result.reasons).to include(a_string_matching(/container=mkv/))
    end

    it 'demotes to :transcode when video codec is incompatible' do
      src = mk_source(streams: [mk_video(codec: 'mpeg4'), mk_audio], container: 'mp4')
      result = described_class.call(media_source: src, profile: browser)
      expect(result.mode).to eq(:transcode)
      expect(result.reasons).to include(a_string_matching(/video_codec=mpeg4/))
    end

    it 'rejects HDR for non-HDR clients' do
      src = mk_source(streams: [mk_video(video_range: 'HDR', video_range_type: 'HDR10'),
                                mk_audio], container: 'mp4')
      result = described_class.call(media_source: src, profile: browser)
      expect(result.mode).to eq(:transcode)
      expect(result.reasons).to include('hdr')
    end

    it 'allows HDR for Apple TV 4K' do
      src = mk_source(streams: [mk_video(video_range: 'HDR', video_range_type: 'HDR10', codec: 'hevc', profile: 'Main10'), mk_audio(codec: 'eac3')],
                      container: 'mp4')
      atv = Jellyfin::Playback::ClientProfile.appletv_4k
      result = described_class.call(media_source: src, profile: atv)
      expect(result.mode).to eq(:direct_play)
    end

    it 'rejects 10-bit when client does not support it' do
      src = mk_source(streams: [mk_video(pixel_format: 'yuv420p10le'), mk_audio], container: 'mp4')
      result = described_class.call(media_source: src, profile: browser)
      expect(result.mode).to eq(:transcode)
      expect(result.reasons).to include('bit_depth_10')
    end

    it 'rejects exceeding max bitrate' do
      src = mk_source(streams: [mk_video(bit_rate: 30_000_000), mk_audio], container: 'mp4')
      result = described_class.call(media_source: src, profile: browser)
      expect(result.mode).to eq(:transcode)
    end

    it 'rejects exceeding max height' do
      src = mk_source(streams: [mk_video(width: 3840, height: 2160), mk_audio], container: 'mp4')
      result = described_class.call(media_source: src, profile: browser)
      expect(result.mode).to eq(:transcode)
    end

    it 'rejects H.264 profile that client does not list' do
      src = mk_source(streams: [mk_video(profile: 'High10'), mk_audio], container: 'mp4')
      result = described_class.call(media_source: src, profile: browser)
      expect(result.mode).to eq(:transcode)
    end

    it 'rejects H.264 level above client max' do
      src = mk_source(streams: [mk_video(level: 52), mk_audio], container: 'mp4')
      result = described_class.call(media_source: src, profile: browser)
      expect(result.mode).to eq(:transcode)
    end

    it 'rejects interlaced when not supported' do
      src = mk_source(streams: [mk_video(field_order: 'tt', is_interlaced: true), mk_audio], container: 'mp4')
      result = described_class.call(media_source: src, profile: browser)
      expect(result.mode).to eq(:transcode)
    end

    it 'rejects anamorphic when not supported' do
      src = mk_source(streams: [mk_video(sample_aspect_ratio: '16:11'), mk_audio], container: 'mp4')
      result = described_class.call(media_source: src, profile: browser)
      expect(result.mode).to eq(:transcode)
    end

    it 'rejects more audio channels than client supports' do
      src = mk_source(streams: [mk_video, mk_audio(channels: 8)], container: 'mp4')
      result = described_class.call(media_source: src, profile: browser)
      expect(result.mode).to eq(:transcode)
    end
  end

  # Regression: empty profile.hevc_profiles used to mean "reject all HEVC"
  # — asymmetric with `h264_profile_ok?` where empty means "accept any".
  # Upstream Jellyfin treats both the same (CodecProfile with no
  # Conditions = no restriction). The asymmetric handling sent every
  # HEVC source through `:transcode` even when the client's profile
  # otherwise advertised HEVC support — particularly painful for
  # Safari, whose native-HLS HEVC path doesn't surface a profile
  # constraint via canPlayType. The fix restores symmetry.
  describe 'HEVC profile constraint' do
    it 'accepts HEVC when profile.hevc_profiles is empty (no constraint)' do
      hevc = mk_video(codec: 'hevc', profile: 'Main', level: 120)
      src = mk_source(streams: [hevc, mk_audio], container: 'mkv')
      profile = Jellyfin::Playback::ClientProfile.new
      profile.containers   = %w[mp4 mkv]
      profile.video_codecs = %w[hevc h264]
      profile.audio_codecs = %w[aac]
      profile.hevc_profiles = []   # no constraint
      result = described_class.call(media_source: src, profile: profile)
      expect(result.mode).to eq(:direct_play)
    end

    it 'rejects HEVC when profile.hevc_profiles is non-empty and source profile is not in list' do
      hevc_high = mk_video(codec: 'hevc', profile: 'Main10', level: 150)
      src = mk_source(streams: [hevc_high, mk_audio], container: 'mkv')
      profile = Jellyfin::Playback::ClientProfile.new
      profile.containers   = %w[mp4 mkv]
      profile.video_codecs = %w[hevc h264]
      profile.audio_codecs = %w[aac]
      profile.hevc_profiles = %w[main]  # Main10 not in list
      result = described_class.call(media_source: src, profile: profile)
      expect(result.mode).to eq(:transcode)
    end
  end
end

RSpec.describe Jellyfin::Playback::RemuxArgs do
  it 'builds a remux command for mp4 with faststart' do
    args = described_class.call(source_path: '/in.mkv', output_path: '/out.mp4', target_container: 'mp4')
    expect(args).to include('-i', '/in.mkv')
    expect(args).to include('-c', 'copy')
    expect(args).to include('-movflags', '+faststart')
    expect(args).to include('-f', 'mp4')
    expect(args.last).to eq('/out.mp4')
  end

  it 'maps mkv container name to matroska muxer' do
    args = described_class.call(source_path: '/a.mp4', output_path: '/b.mkv', target_container: 'mkv')
    expect(args).to include('-f', 'matroska')
  end
end
