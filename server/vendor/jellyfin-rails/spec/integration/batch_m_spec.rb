require 'spec_helper'
require 'tmpdir'

RSpec.describe 'Batch M — Player + streaming gaps' do
  describe Jellyfin::Encoding::BitstreamFilters do
    it 'adds h264_mp4toannexb when targeting HLS/TS with h264 source' do
      args = described_class.for(target_container: 'hls', video_codec: 'h264', audio_codec: 'aac')
      expect(args).to include('-bsf:v', 'h264_mp4toannexb')
    end

    it 'adds hevc_mp4toannexb for HEVC into HLS' do
      args = described_class.for(target_container: 'ts', video_codec: 'hevc')
      expect(args).to include('-bsf:v', 'hevc_mp4toannexb')
    end

    it 'adds aac_adtstoasc for AAC into MP4 container' do
      args = described_class.for(target_container: 'mp4', audio_codec: 'aac')
      expect(args).to include('-bsf:a', 'aac_adtstoasc')
    end

    it 'emits dump_extra for MP4/MKV video for mid-stream tune-in safety' do
      args = described_class.for(target_container: 'mkv', video_codec: 'h264')
      expect(args).to include('-bsf:v', 'dump_extra')
    end

    it 'skips h264_mp4toannexb when source is already Annex B' do
      args = described_class.for(target_container: 'hls', video_codec: 'h264', source_is_avc: false)
      expect(args).not_to include('h264_mp4toannexb')
    end
  end

  describe Jellyfin::Subtitle::Segmenter do
    let(:tmp) { Dir.mktmpdir('seg-') }
    after { FileUtils.rm_rf(tmp) }

    let(:segmenter) { described_class.new(ffmpeg_path: 'ffmpeg', cache_root: tmp) }

    it 'parses WebVTT cues from a body with multiple cues' do
      vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nLine A\n\n00:00:04.500 --> 00:00:07.500\nLine B"
      cues = segmenter.parse_cues(vtt)
      expect(cues.size).to eq(2)
      expect(cues.first.start_seconds).to eq(1.0)
      expect(cues.first.text).to eq('Line A')
      expect(cues.last.end_seconds).to eq(7.5)
    end

    it 'formats seconds back to HH:MM:SS.mmm' do
      expect(segmenter.format_ts(63.5)).to eq('00:01:03.500')
      expect(segmenter.format_ts(3661.25)).to eq('01:01:01.250')
    end

    it 'segments cues into 6-second windows by overlap' do
      # Fake the extract step.
      allow(segmenter).to receive(:extract_to) do |_src, _idx, out|
        File.write(out, "WEBVTT\n\n00:00:01.000 --> 00:00:04.000\nFirst\n\n" \
                        "00:00:05.000 --> 00:00:08.000\nStraddler\n\n" \
                        "00:00:09.000 --> 00:00:11.000\nSecond")
        true
      end
      source = File.join(tmp, 'fake.mkv')
      File.write(source, 'fake')
      result = segmenter.segment(source_path: source, stream_index: 0, segment_length: 6)
      expect(result[:count]).to eq(2)
      seg0 = File.read(File.join(result[:segment_dir], '0.vtt'))
      seg1 = File.read(File.join(result[:segment_dir], '1.vtt'))
      expect(seg0).to include('First')
      expect(seg0).to include('Straddler') # overlaps the 0..6 window
      expect(seg1).to include('Straddler') # also overlaps the 6..12 window
      expect(seg1).to include('Second')
    end
  end

  describe Jellyfin::Output::AudioRendition do
    it 'emits EXT-X-MEDIA TYPE=AUDIO with language + URI' do
      lines = described_class.media_lines([
        { uri: 'audio/eng.m3u8', name: 'English', language: 'en', default: true, channels: 2 },
        { uri: 'audio/jp.m3u8',  name: '日本語',  language: 'ja', default: false, channels: 6 }
      ])
      expect(lines.first).to include('TYPE=AUDIO')
      expect(lines.first).to include('GROUP-ID="audio"')
      expect(lines.first).to include('LANGUAGE="en"')
      expect(lines.first).to include('CHANNELS="2"')
      expect(lines.first).to include('DEFAULT=YES')
      expect(lines.last).to include('CHANNELS="6"')
      expect(lines.last).to include('DEFAULT=NO')
    end

    it 'attribute for the variant references the group id' do
      expect(described_class.stream_inf_audio_attr).to eq('AUDIO="audio"')
      expect(described_class.stream_inf_audio_attr(group: 'main-audio')).to eq('AUDIO="main-audio"')
    end
  end

  describe Jellyfin::Encoding::Filters::HwSubtitleOverlay do
    def job_with_subs(codec)
      v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'hevc')
      s = Jellyfin::Probing::MediaStream.new(index: 1, type: :subtitle, codec: codec)
      src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x', streams: [v, s])
      Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, output_video_codec: 'h265',
        subtitle_stream: s, subtitle_method: :encode)
    end

    it 'emits overlay_cuda for NVENC + PGS subs' do
      expect(described_class.build(job_with_subs('hdmv_pgs_subtitle'), :nvenc))
        .to start_with('overlay_cuda')
    end

    it 'emits overlay_qsv for Intel Quick Sync' do
      expect(described_class.build(job_with_subs('pgssub'), :qsv))
        .to start_with('overlay_qsv')
    end

    it 'emits overlay_vaapi for Linux VA-API' do
      expect(described_class.build(job_with_subs('hdmv_pgs_subtitle'), :vaapi))
        .to start_with('overlay_vaapi')
    end

    it 'falls back to nil for VideoToolbox (no HW overlay filter)' do
      expect(described_class.build(job_with_subs('hdmv_pgs_subtitle'), :videotoolbox)).to be_nil
    end

    it 'is nil for text subs (regular subtitles filter handles them)' do
      expect(described_class.build(job_with_subs('subrip'), :nvenc)).to be_nil
    end
  end

  describe 'EncodingHelper HLS output integration' do
    let(:caps) do
      Class.new do
        def supports_encoder?(name) %w[libx264 libx265 aac].include?(name) end
        def supports_filter?(_) true end
        def supports_hwaccel?(_) false end
        def supports_decoder?(_) true end
      end.new
    end

    # Updated contract (2026-05-14): the h264_mp4toannexb bitstream filter
    # only applies on stream-COPY paths. Mirrors upstream Jellyfin's
    # EncodingHelper.GetProgressiveVideoArguments which gates the filter
    # behind `IsCopyCodec(videoCodec)`. Re-encoded output (libx264 /
    # h264_videotoolbox / etc.) is already Annex-B for TS containers;
    # double-applying the filter corrupts the bitstream and the browser
    # rejects the segments with MEDIA_ERR_SRC_NOT_SUPPORTED.
    def avc_h264_aac_source
      v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264',
        width: 1920, height: 1080, frame_rate: 24.0, pixel_format: 'yuv420p',
        sample_aspect_ratio: '1:1', is_interlaced: false, video_range_type: 'SDR',
        is_avc: true)
      a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac',
        channels: 2, sample_rate: 48_000)
      Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: [v, a])
    end

    it 'omits -bsf:v h264_mp4toannexb when re-encoding (output != copy)' do
      job = Jellyfin::Encoding::EncodingJobInfo.new(
        media_source: avc_h264_aac_source,
        output_video_codec: 'h264',  # transcode
        output_audio_codec: 'aac'
      )
      args = Jellyfin::Encoding::EncodingHelper.command_line_arguments(
        job, playlist_path: '/tmp/p.m3u8', segment_template: '/tmp/%d.ts', capabilities: caps
      )
      expect(args).not_to include('h264_mp4toannexb')
    end

    it 'emits -bsf:v h264_mp4toannexb on a stream-copy path (avcC source → TS)' do
      job = Jellyfin::Encoding::EncodingJobInfo.new(
        media_source: avc_h264_aac_source,
        output_video_codec: 'copy',
        output_audio_codec: 'aac'
      )
      args = Jellyfin::Encoding::EncodingHelper.command_line_arguments(
        job, playlist_path: '/tmp/p.m3u8', segment_template: '/tmp/%d.ts', capabilities: caps
      )
      bsf_idx = args.index('-bsf:v')
      expect(bsf_idx).not_to be_nil
      expect(args[bsf_idx + 1]).to eq('h264_mp4toannexb')
    end
  end
end

RSpec.describe 'Batch M — Controllers', type: :request do
  let(:fixture) { File.join(FIXTURE_PATH, 'sample.mp4') }
  let(:tmp_root) { Dir.mktmpdir('jelly-m-') }

  before do
    skip 'fixture missing' unless File.exist?(fixture)
    ffmpeg = ENV.fetch('TEST_FFMPEG_PATH', '/Applications/Jellyfin.app/Contents/MacOS/ffmpeg')
    skip 'ffmpeg not present' unless File.executable?(ffmpeg)
    Jellyfin::Transcoding::TranscodeManager.reset!
    Jellyfin::Transcoding::LiveStreamRegistry.reset!
    Jellyfin::Rails.configure do |c|
      c.ffmpeg_path = ffmpeg
      c.transcode_dir = tmp_root
      c.token_secret = 'batch-m'
      c.allowed_paths = [FIXTURE_PATH]
      c.segment_length = 1
    end
  end

  after do
    Jellyfin::Transcoding::TranscodeManager.reset!
    Jellyfin::Transcoding::LiveStreamRegistry.reset!
    FileUtils.rm_rf(tmp_root)
  end

  describe 'GET /stream/:token/remux.:container' do
    it 'returns 200 with video/mp4 content-type (body streams via Rack)' do
      token = Jellyfin::Transcoding::Token.encode(path: fixture)
      get "/jellyfin/stream/#{token}/remux.mp4"
      expect(response).to have_http_status(:ok)
      expect(response.headers['Content-Type']).to eq('video/mp4')
      # Streaming bodies aren't materialised in Rails request specs;
      # functional correctness of -c copy is verified by RemuxArgs unit tests.
    end

    it 'route constraint rejects unsupported containers' do
      token = Jellyfin::Transcoding::Token.encode(path: fixture)
      expect {
        get "/jellyfin/stream/#{token}/remux.flac"
      }.to raise_error(ActionController::RoutingError)
    end
  end

  describe 'live_streams open/close/active' do
    it 'opens, lists, and closes a live source' do
      post '/jellyfin/live_streams/open', params: { url: 'rtsp://camera/live.sdp' }, as: :json
      expect(response).to have_http_status(:ok)
      id = JSON.parse(response.body)['id']
      expect(id).to be_a(String)

      get '/jellyfin/live_streams/active'
      list = JSON.parse(response.body)
      expect(list['count']).to be >= 1
      expect(list['streams'].map { |s| s['id'] }).to include(id)

      post '/jellyfin/live_streams/close', params: { id: id }, as: :json
      expect(response).to have_http_status(:no_content)
    end

    it 'rejects schemes outside the allow list' do
      post '/jellyfin/live_streams/open', params: { url: 'file:///etc/passwd' }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
