require 'spec_helper'
require 'tmpdir'

RSpec.describe 'Batch S — Progressive streaming' do
  let(:fixture) { File.join(FIXTURE_PATH, 'sample.mp4') }
  let(:tmp_root) { Dir.mktmpdir('jelly-s-') }

  before do
    skip 'fixture missing' unless File.exist?(fixture)
    ffmpeg = ENV.fetch('TEST_FFMPEG_PATH', '/Applications/Jellyfin.app/Contents/MacOS/ffmpeg')
    skip 'ffmpeg not present' unless File.executable?(ffmpeg)
    Jellyfin::Transcoding::TranscodeManager.reset!
    Jellyfin::Rails.configure do |c|
      c.ffmpeg_path = ffmpeg
      c.transcode_dir = tmp_root
      c.token_secret = 'batch-s'
      c.allowed_paths = [FIXTURE_PATH]
    end
  end

  after do
    Jellyfin::Transcoding::TranscodeManager.reset!
    FileUtils.rm_rf(tmp_root)
  end

  describe Jellyfin::Encoding::ProgressiveVideo do
    let(:caps) do
      Class.new do
        def supports_encoder?(name) %w[libx264 libx265 aac].include?(name) end
        def supports_filter?(_) true end
        def supports_hwaccel?(_) false end
        def supports_decoder?(_) true end
      end.new
    end

    it 'emits -codec:v:0 + -codec:a:0 with positional stream specs (upstream cs:7626)' do
      v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264',
        width: 1920, height: 1080, frame_rate: 24.0, pixel_format: 'yuv420p',
        sample_aspect_ratio: '1:1', is_interlaced: false, video_range_type: 'SDR')
      a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac',
        channels: 2, sample_rate: 48_000)
      src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: [v, a])
      job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src,
        output_video_codec: 'h264', output_audio_codec: 'aac')

      args = described_class.command_line(job: job, output_path: '/tmp/x.mp4', capabilities: caps)
      expect(args).to include('-codec:v:0', 'libx264')
      expect(args).to include('-codec:a:0', 'aac')
    end

    it 'emits the MP4 streaming-friendly movflags for .mp4 outputs (upstream cs:7586)' do
      v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264',
        width: 1920, height: 1080, frame_rate: 24.0, pixel_format: 'yuv420p',
        sample_aspect_ratio: '1:1', is_interlaced: false, video_range_type: 'SDR')
      a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac',
        channels: 2, sample_rate: 48_000)
      src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: [v, a])
      job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src,
        output_video_codec: 'h264', output_audio_codec: 'aac')

      args = described_class.command_line(job: job, output_path: '/tmp/x.mp4', capabilities: caps)
      mov_idx = args.index('-movflags')
      expect(args[mov_idx + 1]).to eq('frag_keyframe+empty_moov+delay_moov')
    end

    it 'short-circuits to -codec:v:0 copy when output codec is copy (upstream cs:7633)' do
      v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264', width: 1920, height: 1080)
      a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac', channels: 2)
      src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x', streams: [v, a])
      job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src,
        output_video_codec: 'copy', output_audio_codec: 'aac')
      args = described_class.command_line(job: job, output_path: '/tmp/x.mp4', capabilities: caps)
      idx = args.index('-codec:v:0')
      expect(args[idx + 1]).to eq('copy')
    end

    it 'maps -map_metadata -1 / -map_chapters -1 like upstream' do
      v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264', width: 1920, height: 1080)
      a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac', channels: 2)
      src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x', streams: [v, a])
      job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src,
        output_video_codec: 'h264', output_audio_codec: 'aac')
      args = described_class.command_line(job: job, output_path: '/tmp/x.mp4', capabilities: caps)
      expect(args).to include('-map_metadata', '-1')
      expect(args).to include('-map_chapters', '-1')
    end
  end

  describe Jellyfin::Encoding::ProgressiveAudio do
    let(:caps) do
      Class.new do
        def supports_encoder?(n); %w[libmp3lame aac flac libopus pcm_s16le].include?(n); end
        def supports_filter?(_); true; end
        def supports_hwaccel?(_); false; end
        def supports_decoder?(_); true; end
      end.new
    end

    let(:job) do
      v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264')
      a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac',
        channels: 2, sample_rate: 48_000)
      src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x', streams: [v, a])
      Jellyfin::Encoding::EncodingJobInfo.new(media_source: src,
        output_audio_codec: 'mp3', output_audio_bitrate: 192_000,
        output_audio_channels: 2, output_audio_sample_rate: 48_000)
    end

    it 'emits -vn to drop video for audio-only output (upstream cs:7836)' do
      args = described_class.command_line(job: job, output_path: '/tmp/x.mp3', capabilities: caps)
      expect(args).to include('-vn')
    end

    it 'emits -ab + -ac + -acodec for the chosen codec' do
      args = described_class.command_line(job: job, output_path: '/tmp/x.mp3', capabilities: caps)
      expect(args).to include('-ab', '192000')
      expect(args).to include('-ac', '2')
      expect(args).to include('-acodec', 'libmp3lame')
    end

    it 'skips -ab for lossless codecs (upstream cs:7771)' do
      job.instance_variable_set(:@output_audio_codec, 'flac')
      args = described_class.command_line(job: job, output_path: '/tmp/x.flac', capabilities: caps)
      expect(args).not_to include('-ab')
    end

    it 'emits ID3 tagging args for non-PCM containers (upstream cs:7832)' do
      args = described_class.command_line(job: job, output_path: '/tmp/x.mp3', capabilities: caps)
      expect(args).to include('-id3v2_version', '3', '-write_id3v1', '1')
    end

    it 'quantises sample rate to the 8k/12k/16k/24k/48k tiers (upstream cs:7806)' do
      [(5_000), 9_000, 16_000, 22_000, 88_200, 192_000].each do |rate|
        expect(described_class.quantize_rate(rate)).to be_in([8_000, 12_000, 16_000, 24_000, 48_000])
      end
    end

    it 'PCM encoder triggers the raw-format flag (upstream cs:7794)' do
      # CodecSelector returns the codec name verbatim for pcm_s16le; setting
      # the output codec directly mirrors what AudioStreamController does.
      job.instance_variable_set(:@output_audio_codec, 'pcm_s16le')
      args = described_class.command_line(job: job, output_path: '/tmp/x.wav', capabilities: caps)
      f_idx = args.index('-f')
      expect(f_idx).not_to be_nil
      expect(args[f_idx + 1]).to eq('s16le')
    end
  end

  describe 'GET/HEAD /videos/:token/stream + .:container', type: :request do
    it 'serves a streamed mp4 over HTTP' do
      token = Jellyfin::Transcoding::Token.encode(path: fixture)
      get "/jellyfin/videos/#{token}/stream.mp4"
      expect(response).to have_http_status(:ok)
      expect(response.headers['Content-Type']).to eq('video/mp4')
    end

    it 'responds to HEAD with the codec content-type only' do
      token = Jellyfin::Transcoding::Token.encode(path: fixture)
      head "/jellyfin/videos/#{token}/stream.mp4"
      expect(response).to have_http_status(:ok)
      expect(response.headers['Content-Type']).to eq('video/mp4')
    end

    it 'route constraint rejects unsupported containers' do
      token = Jellyfin::Transcoding::Token.encode(path: fixture)
      expect { get "/jellyfin/videos/#{token}/stream.flac" }
        .to raise_error(ActionController::RoutingError)
    end
  end

  describe 'GET/HEAD /audio_stream/:token/stream + .:container', type: :request do
    it 'serves a streamed mp3 over HTTP' do
      token = Jellyfin::Transcoding::Token.encode(path: fixture)
      get "/jellyfin/audio_stream/#{token}/stream.mp3"
      expect(response).to have_http_status(:ok)
      expect(response.headers['Content-Type']).to eq('audio/mpeg')
    end

    it 'responds to HEAD with audio content-type' do
      token = Jellyfin::Transcoding::Token.encode(path: fixture)
      head "/jellyfin/audio_stream/#{token}/stream.aac"
      expect(response).to have_http_status(:ok)
      expect(response.headers['Content-Type']).to eq('audio/aac')
    end
  end
end
