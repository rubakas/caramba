require 'spec_helper'

RSpec.describe Jellyfin::Output::MasterPlaylistBuilder do
  let(:video) do
    Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264',
      width: 1920, height: 1080, frame_rate: 24.0, profile: 'high', level: 41,
      video_range_type: 'SDR')
  end

  let(:audio) do
    Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac', channels: 2)
  end

  let(:job) do
    double('job') # only used for type signature; the builder doesn't dig into the job in the basic case
  end

  describe '.build' do
    it 'emits #EXTM3U + a single STREAM-INF + variant URL when there are no rendition groups' do
      out = described_class.build(
        job: job, variant_url: 'main.m3u8', total_bitrate: 3_000_000,
        video_stream: video, audio_stream: audio
      )
      expect(out).to start_with('#EXTM3U')
      expect(out).to include('#EXT-X-STREAM-INF:BANDWIDTH=3000000')
      expect(out).to include('AVERAGE-BANDWIDTH=3000000')
      expect(out).to include('CODECS="avc1.640029,mp4a.40.2"')
      expect(out).to include('RESOLUTION=1920x1080')
      expect(out).to include('FRAME-RATE=24.000')
      expect(out).to include('VIDEO-RANGE=SDR')
      expect(out).to match(/^main\.m3u8$/)
    end

    it 'inserts #EXT-X-MEDIA TYPE=SUBTITLES lines before STREAM-INF and references group on the variant' do
      subs = [
        { stream_index: 2, uri: 'subs/2.m3u8', name: 'English', language: 'eng', default: true, forced: false },
        { stream_index: 3, uri: 'subs/3.m3u8', name: 'French',  language: 'fra', default: false, forced: true }
      ]
      out = described_class.build(
        job: job, variant_url: 'main.m3u8', total_bitrate: 3_000_000,
        video_stream: video, audio_stream: audio, subtitle_tracks: subs
      )
      lines = out.lines.map(&:chomp)
      stream_inf_idx = lines.index { |l| l.start_with?('#EXT-X-STREAM-INF') }
      media_idx = lines.index { |l| l.start_with?('#EXT-X-MEDIA:TYPE=SUBTITLES') }
      expect(media_idx).to be < stream_inf_idx
      expect(lines.count { |l| l.start_with?('#EXT-X-MEDIA:TYPE=SUBTITLES') }).to eq(2)
      expect(out).to include('SUBTITLES="subs"')
      expect(out).to include('FORCED=YES')
      expect(out).to include('DEFAULT=YES')
      expect(out).to include('LANGUAGE="eng"')
    end

    it 'includes AUDIO rendition group when audio_renditions present' do
      auds = [{ uri: 'audio/eng.m3u8', name: 'English', language: 'eng', default: true, channels: 2 }]
      out = described_class.build(
        job: job, variant_url: 'main.m3u8', total_bitrate: 3_000_000,
        video_stream: video, audio_stream: audio, audio_renditions: auds
      )
      expect(out).to include('#EXT-X-MEDIA:TYPE=AUDIO')
      expect(out).to include('AUDIO="audio"')
    end

    it 'includes CLOSED-CAPTIONS group when has_closed_captions is true' do
      out = described_class.build(
        job: job, variant_url: 'main.m3u8', total_bitrate: 3_000_000,
        video_stream: video, audio_stream: audio, has_closed_captions: true
      )
      expect(out).to include('#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS')
      expect(out).to include('CLOSED-CAPTIONS="cc"')
    end

    it 'appends EXT-X-IMAGE-STREAM-INF trickplay lines for VOD streams' do
      tp = [{ width: 320, height: 180, bandwidth: 460_800, uri: 'trickplay/320/index.m3u8' }]
      out = described_class.build(
        job: job, variant_url: 'main.m3u8', total_bitrate: 3_000_000,
        video_stream: video, audio_stream: audio, trickplay_resolutions: tp,
        is_live_stream: false
      )
      expect(out).to include('#EXT-X-IMAGE-STREAM-INF:BANDWIDTH=460800')
      expect(out).to include('RESOLUTION=320x180')
      expect(out).to include('CODECS="jpeg"')
      expect(out).to include('URI="trickplay/320/index.m3u8"')
    end

    it 'skips trickplay lines for live streams' do
      tp = [{ width: 320, height: 180, bandwidth: 460_800, uri: 'tp/index.m3u8' }]
      out = described_class.build(
        job: job, variant_url: 'live.m3u8', total_bitrate: 3_000_000,
        video_stream: video, audio_stream: audio, trickplay_resolutions: tp,
        is_live_stream: true
      )
      expect(out).not_to include('#EXT-X-IMAGE-STREAM-INF')
    end

    it 'maps HDR10 video_range_type to PQ' do
      hdr = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'hevc',
        width: 3840, height: 2160, video_range_type: 'HDR10')
      out = described_class.build(
        job: job, variant_url: 'main.m3u8', total_bitrate: 10_000_000,
        video_stream: hdr, audio_stream: audio
      )
      expect(out).to include('VIDEO-RANGE=PQ')
    end
  end
end

RSpec.describe 'EncodingHelper HLS live-vs-vod', type: :model do
  let(:caps) do
    Class.new do
      def supports_encoder?(name) %w[libx264 libx265 aac].include?(name) end
      def supports_filter?(_) true end
      def supports_hwaccel?(_) false end
      def supports_decoder?(_) true end
    end.new
  end

  def make_job(run_time_ticks:)
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264',
      width: 1920, height: 1080, frame_rate: 24.0, pixel_format: 'yuv420p',
      sample_aspect_ratio: '1:1', is_interlaced: false, video_range_type: 'SDR', is_avc: true)
    a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac',
      channels: 2, sample_rate: 48_000)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: [v, a],
      run_time_ticks: run_time_ticks)
    Jellyfin::Encoding::EncodingJobInfo.new(media_source: src,
      output_video_codec: 'h264', output_audio_codec: 'aac')
  end

  it 'emits hls_playlist_type=event for VOD (run_time_ticks present)' do
    job = make_job(run_time_ticks: 600_000_000)
    args = Jellyfin::Encoding::EncodingHelper.command_line_arguments(
      job, playlist_path: '/tmp/p.m3u8', segment_template: '/tmp/%d.ts', capabilities: caps
    )
    idx = args.index('-hls_playlist_type')
    expect(args[idx + 1]).to eq('event')
  end

  it 'emits hls_playlist_type=live for segmented-live streams (run_time_ticks nil)' do
    job = make_job(run_time_ticks: nil)
    args = Jellyfin::Encoding::EncodingHelper.command_line_arguments(
      job, playlist_path: '/tmp/p.m3u8', segment_template: '/tmp/%d.ts', capabilities: caps
    )
    idx = args.index('-hls_playlist_type')
    expect(args[idx + 1]).to eq('live')
  end

  it 'splices HlsEncryption -hls_enc flags when material is on options' do
    tmp = Dir.mktmpdir
    job = make_job(run_time_ticks: 600_000_000)
    job.options.hls_encryption_material = Jellyfin::Output::HlsEncryption.generate!(
      session_dir: tmp, key_uri: 'http://x/k.key'
    )
    args = Jellyfin::Encoding::EncodingHelper.command_line_arguments(
      job, playlist_path: '/tmp/p.m3u8', segment_template: '/tmp/%d.ts', capabilities: caps
    )
    expect(args).to include('-hls_enc', '1')
    expect(args).to include('-hls_enc_key_url', 'http://x/k.key')
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end
end

# Regression: the CODECS attribute must reflect what ffmpeg actually emits,
# not the source. Without this, an HEVC source transcoded to H.264
# produced CODECS="hev1..." in the master playlist, which Chrome/Firefox
# reject with MEDIA_ERR_SRC_NOT_SUPPORTED before any segment loads.
RSpec.describe Jellyfin::Output::MasterPlaylistBuilder do
  let(:hevc_source) do
    Jellyfin::Probing::MediaStream.new(
      index: 0, type: :video, codec: 'hevc', width: 1920, height: 1080,
      frame_rate: 24.0, profile: 'Main', level: 153,
      video_range_type: 'HDR10'
    )
  end
  let(:ac3_source) do
    Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'ac3', channels: 6)
  end
  let(:job) { double('job') }

  context 'with output codec overrides (transcode path)' do
    it 'announces the output codecs (h264/aac), not the source (hevc/ac3)' do
      out = described_class.build(
        job: job, variant_url: 'main.m3u8', total_bitrate: 3_000_000,
        video_stream: hevc_source, audio_stream: ac3_source,
        output_video_codec: 'h264', output_audio_codec: 'aac'
      )
      expect(out).to match(/CODECS="avc1\.[0-9a-f]+,mp4a\.40\.2"/)
      expect(out).not_to include('hev1')
      expect(out).not_to include('hvc1')
      expect(out).not_to include('ac-3')
    end

    it 'forces SDR VIDEO-RANGE when transcoding from HDR (software H.264 emits SDR)' do
      out = described_class.build(
        job: job, variant_url: 'main.m3u8', total_bitrate: 3_000_000,
        video_stream: hevc_source, audio_stream: ac3_source,
        output_video_codec: 'h264', output_audio_codec: 'aac'
      )
      expect(out).to include('VIDEO-RANGE=SDR')
      expect(out).not_to include('VIDEO-RANGE=PQ')
    end

    it 'pins announced H.264 level to 4.0 regardless of source HEVC level (5.x is invalid for AVC)' do
      out = described_class.build(
        job: job, variant_url: 'main.m3u8', total_bitrate: 3_000_000,
        video_stream: hevc_source, audio_stream: ac3_source,
        output_video_codec: 'h264', output_audio_codec: 'aac'
      )
      # avc1.PPCCLL — last two hex digits are level*10 in hex.
      # 4.0 → 0x28. Anything ≥0x33 (5.1) would be rejected by the browser
      # for an AVC stream (those are HEVC level codes mistakenly carried over).
      expect(out).to match(/avc1\.[0-9a-f]{2}[0-9a-f]{2}28/i)
    end
  end

  context 'without output codec overrides (legacy callers, copy/remux path)' do
    it 'falls back to the source codec for backward compat' do
      out = described_class.build(
        job: job, variant_url: 'main.m3u8', total_bitrate: 3_000_000,
        video_stream: hevc_source, audio_stream: ac3_source
      )
      # Legacy behaviour preserved: caller passing source streams without
      # overrides gets the source codec announcement. This is correct for
      # direct_stream (-c copy) where the bytes ARE the source bytes.
      expect(out).to match(/CODECS="(hev1|hvc1)\./)
    end
  end
end

RSpec.describe 'TranscodeManager build_encoding_options' do
  it 'maps params hash → EncodingOptions for Batch-J knobs' do
    manager = Jellyfin::Transcoding::TranscodeManager.new
    job = double(id: 'test',
                 dir: '/tmp',
                 params: {
                   auto_crop: true, two_pass: true, frame_interpolation: true,
                   target_framerate: 60, multi_audio_tracks: true,
                   force_accurate_seek: true, enable_loudnorm: true, enable_drc: true,
                   http_user_agent: 'TestAgent/1.0',
                   http_headers: { 'X-Auth' => 'bearer' },
                   concat_parts: ['/a.mkv', '/b.mkv']
                 })
    opts = manager.send(:build_encoding_options, job)
    expect(opts.auto_crop).to be(true)
    expect(opts.two_pass).to be(true)
    expect(opts.target_framerate).to eq(60)
    expect(opts.multi_audio_tracks).to be(true)
    expect(opts.http_user_agent).to eq('TestAgent/1.0')
    expect(opts.http_headers).to eq({ 'X-Auth' => 'bearer' })
    expect(opts.concat_parts).to eq(['/a.mkv', '/b.mkv'])
  end
end
