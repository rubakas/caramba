require 'spec_helper'
require 'tmpdir'

RSpec.describe 'Batch J — FFmpeg arg generation' do
  def video_stream(**ov)
    Jellyfin::Probing::MediaStream.new(
      index: 0, type: :video, codec: 'h264',
      width: 1920, height: 1080, frame_rate: 24.0, pixel_format: 'yuv420p',
      sample_aspect_ratio: '1:1', is_interlaced: false,
      video_range_type: 'SDR',
      **ov
    )
  end

  def make_job(stream: video_stream, path: '/tmp/x.mkv', **opts)
    a = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac', channels: 2, sample_rate: 48_000)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: path, streams: [stream, a])
    options = Jellyfin::Encoding::EncodingOptions.new
    opts.each { |k, v| options.public_send("#{k}=", v) }
    Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, options: options,
      output_video_codec: 'h264', output_audio_codec: 'aac')
  end

  describe Jellyfin::Encoding::Filters::Rotation do
    it 'emits transpose=1 for 90° rotation' do
      expect(described_class.build(make_job(stream: video_stream(rotation: 90)))).to eq('transpose=1')
    end

    it 'emits two transposes for 180°' do
      expect(described_class.build(make_job(stream: video_stream(rotation: 180)))).to eq('transpose=1,transpose=1')
    end

    it 'emits transpose=2 for 270°' do
      expect(described_class.build(make_job(stream: video_stream(rotation: 270)))).to eq('transpose=2')
    end

    it 'is nil when no rotation is present' do
      expect(described_class.build(make_job)).to be_nil
    end

    it 'clears the rotate=0 metadata after baking the rotation in' do
      args = described_class.metadata_args(make_job(stream: video_stream(rotation: 90)))
      expect(args).to eq(['-metadata:s:v:0', 'rotate=0'])
    end

    it 'normalises negative degrees' do
      expect(described_class.build(make_job(stream: video_stream(rotation: -90)))).to eq('transpose=2')
    end
  end

  describe Jellyfin::Encoding::Filters::CropDetect do
    before { described_class.instance_variable_set(:@cache, {}) }

    it 'returns nil when auto_crop is off (default)' do
      expect(described_class.build(make_job)).to be_nil
    end

    it 'reads the last crop= line from cropdetect output' do
      stderr = "Parsed_cropdetect crop=1920:800:0:140\n" \
               "Parsed_cropdetect crop=1920:800:0:140\n"
      allow(Open3).to receive(:capture3).and_return(['', stderr, instance_double(Process::Status, success?: true)])
      allow(File).to receive(:exist?).and_return(true)
      job = make_job(auto_crop: true, path: '/tmp/scene1.mkv')
      expect(described_class.build(job)).to eq('crop=1920:800:0:140')
    end

    it 'rejects implausibly large crops as false positives' do
      stderr = 'Parsed_cropdetect crop=1920:200:0:440' # crops 80% of height
      allow(Open3).to receive(:capture3).and_return(['', stderr, instance_double(Process::Status, success?: true)])
      allow(File).to receive(:exist?).and_return(true)
      job = make_job(auto_crop: true, path: '/tmp/scene2.mkv')
      expect(described_class.build(job)).to be_nil
    end
  end

  describe Jellyfin::Encoding::InputSource do
    it 'classifies HTTP URLs and emits -reconnect + -user_agent' do
      job = make_job(path: 'https://example.com/movie.mp4',
                     http_user_agent: 'MyAgent/1.0',
                     http_headers: { 'Authorization' => 'Bearer xyz' })
      args, _cleanup = described_class.build(job)
      expect(args).to include('-reconnect', '1')
      expect(args).to include('-user_agent', 'MyAgent/1.0')
      hdr_idx = args.index('-headers')
      expect(args[hdr_idx + 1]).to include('Authorization: Bearer xyz')
    end

    it 'classifies RTSP streams and emits -re for real-time pacing' do
      job = make_job(path: 'rtsp://camera/live.sdp')
      args, _ = described_class.build(job)
      expect(args).to include('-re')
    end

    it 'builds a concat manifest when concat_parts is set' do
      tmp = Dir.mktmpdir
      part1 = File.join(tmp, 'cd1.mkv'); File.write(part1, '')
      part2 = File.join(tmp, 'cd2.mkv'); File.write(part2, '')
      job = make_job(concat_parts: [part1, part2])
      args, cleanup = described_class.build(job)
      expect(args).to include('-f', 'concat', '-safe', '0', '-i')
      list = args.last
      expect(File.read(list)).to include("file '#{part1}'")
      cleanup.call
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it 'falls back to a plain -i for local files' do
      job = make_job(path: '/local/movie.mkv')
      args, _ = described_class.build(job)
      expect(args).to eq(['-i', '/local/movie.mkv'])
    end
  end

  describe Jellyfin::Encoding::ProbeTuning do
    it 'scales probesize up for >25 Mbps content' do
      v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'hevc', width: 3840, height: 2160)
      src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x', streams: [v], bit_rate: 60_000_000)
      job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, output_video_codec: 'h265')
      size, dur = described_class.budget_for(job)
      expect(size).to be > 25 * 1024 * 1024
      expect(dur).to eq(20_000_000)
    end

    it 'uses a small budget for low-bitrate audio-only sources' do
      v = Jellyfin::Probing::MediaStream.new(index: 0, type: :audio, codec: 'aac')
      src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x', streams: [v], bit_rate: 192_000)
      job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, output_video_codec: 'h264')
      size, dur = described_class.budget_for(job)
      expect(size).to eq(10 * 1024 * 1024)
      expect(dur).to eq(5_000_000)
    end

    it 'emits -probesize and -analyzeduration on input_args' do
      v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264')
      src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x', streams: [v])
      job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, output_video_codec: 'h264')
      args = described_class.input_args(job)
      expect(args).to include('-probesize')
      expect(args).to include('-analyzeduration')
    end
  end

  describe Jellyfin::Encoding::TwoPass do
    it 'is disabled by default' do
      expect(described_class.enabled?(make_job)).to be(false)
    end

    it 'pass-1 args drop audio and use -f null' do
      args = described_class.pass1_args('/tmp/log')
      expect(args).to include('-pass', '1')
      expect(args).to include('-an')
      expect(args).to include('-f', 'null')
    end

    it 'pass-2 args reference the same passlog' do
      args = described_class.pass2_args('/tmp/log')
      expect(args).to include('-pass', '2', '-passlogfile', '/tmp/log')
    end
  end

  describe Jellyfin::Encoding::ColorMatrix do
    it 'emits bt2020nc → bt709 when downscaling 4K HDR to 1080p' do
      job = make_job(stream: video_stream(color_space: 'bt2020nc', width: 3840, height: 2160))
      job.instance_variable_set(:@output_height, 1080)
      expect(described_class.build(job)).to eq('colormatrix=bt2020nc:bt709')
    end

    it 'is nil when source and target colourspace match' do
      job = make_job(stream: video_stream(color_space: 'bt709', width: 1920, height: 1080))
      expect(described_class.build(job)).to be_nil
    end

    it 'emits bt709 → bt601 when downscaling HD to SD' do
      job = make_job(stream: video_stream(color_space: 'bt709', width: 1920, height: 1080))
      job.instance_variable_set(:@output_height, 480)
      expect(described_class.build(job)).to eq('colormatrix=bt709:bt601')
    end
  end

  describe Jellyfin::Encoding::FrameInterp do
    it 'is nil unless explicitly enabled' do
      expect(described_class.build(make_job)).to be_nil
    end

    it 'emits minterpolate when target_framerate exceeds source' do
      job = make_job(frame_interpolation: true, target_framerate: 60)
      expect(described_class.build(job)).to eq('minterpolate=fps=60:mi_mode=mci')
    end

    it 'is nil when target_framerate is below or equal to source' do
      job = make_job(stream: video_stream(frame_rate: 60.0),
                     frame_interpolation: true, target_framerate: 30)
      expect(described_class.build(job)).to be_nil
    end
  end

  describe Jellyfin::Encoding::Hdr10Plus do
    it 'detects HDR10+ from the probe-derived flag' do
      stream = video_stream(hdr10plus_present: true)
      expect(described_class.present?(stream)).to be(true)
    end

    it 'emits x265 SEI passthrough params' do
      stream = video_stream(hdr10plus_present: true)
      expect(described_class.x265_params(stream)).to include('dhdr10-opt=1')
    end

    it 'is nil for non-HDR10+ streams' do
      expect(described_class.x265_params(video_stream)).to be_nil
    end
  end

  describe Jellyfin::Encoding::LoudnormTwoPass do
    it 'parses the JSON measurement from ffmpeg stderr' do
      json = '{"input_i":"-20.5","input_tp":"-1.2","input_lra":"5.0","input_thresh":"-30.0","target_offset":"0.5"}'
      stderr = "some preamble\nfoo bar\n" + json
      allow(Open3).to receive(:capture3).and_return(['', stderr, instance_double(Process::Status, success?: true)])
      allow(File).to receive(:mtime).and_return(Time.at(0))
      m = described_class.measure('/fake.mkv', audio_index: 0, ffmpeg_path: 'ffmpeg')
      expect(m.input_i).to eq(-20.5)
      expect(m.target_offset).to eq(0.5)
      filter = m.to_filter
      expect(filter).to include('measured_I=-20.5')
      expect(filter).to include('linear=true')
    end

    it 'returns nil when ffmpeg fails' do
      allow(Open3).to receive(:capture3).and_return(['', '', instance_double(Process::Status, success?: false)])
      allow(File).to receive(:mtime).and_return(Time.at(0))
      described_class.instance_variable_set(:@cache, nil)
      expect(described_class.measure('/x.mkv', audio_index: 0, ffmpeg_path: 'ffmpeg')).to be_nil
    end
  end

  describe Jellyfin::Encoding::MultiAudio do
    it 'is disabled unless multi_audio_tracks=true' do
      expect(described_class.enabled?(make_job)).to be(false)
    end

    it 'emits per-track -map and per-track codec args when enabled' do
      v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264')
      a1 = Jellyfin::Probing::MediaStream.new(index: 1, type: :audio, codec: 'aac', channels: 2, language: 'eng')
      a2 = Jellyfin::Probing::MediaStream.new(index: 2, type: :audio, codec: 'aac', channels: 6, language: 'fra')
      src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x', streams: [v, a1, a2])
      opts = Jellyfin::Encoding::EncodingOptions.new
      opts.multi_audio_tracks = true
      job = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, options: opts,
        output_video_codec: 'h264', output_audio_codec: 'aac')

      args = described_class.args(job, single_track_args: ['-c:a', 'aac', '-b:a', '128000', '-ac', '2', '-ar', '48000'])
      expect(args).to include('-map', '0:a:0?')
      expect(args).to include('-map', '0:a:1?')
      expect(args).to include('-c:a:0', 'aac')
      expect(args).to include('-c:a:1', 'aac')
      expect(args.any? { |s| s.to_s.include?('language=eng') }).to be(true)
      expect(args.any? { |s| s.to_s.include?('language=fra') }).to be(true)
    end
  end

  describe Jellyfin::Encoding::WebvttSubs do
    it 'builds a master-playlist #EXT-X-MEDIA SUBTITLES line per track' do
      lines = described_class.master_media_lines([
        { uri: 'subs/en.m3u8', name: 'English', language: 'en', default: true, forced: false },
        { uri: 'subs/jp.m3u8', name: '日本語',    language: 'ja', default: false, forced: true }
      ])
      expect(lines.first).to include('TYPE=SUBTITLES')
      expect(lines.first).to include('NAME="English"')
      expect(lines.first).to include('LANGUAGE="en"')
      expect(lines.first).to include('DEFAULT=YES')
      expect(lines.first).to include('AUTOSELECT=YES')
      expect(lines.first).to include('URI="subs/en.m3u8"')
      expect(lines.last).to include('FORCED=YES')
    end

    it 'builds a per-track playlist listing the segment URIs' do
      pls = described_class.per_track_playlist(
        segments: ['000.vtt', '001.vtt', '002.vtt'],
        segment_length: 6, total_duration: 14
      )
      expect(pls).to start_with('#EXTM3U')
      expect(pls).to include('#EXT-X-VERSION:6')
      expect(pls).to include('#EXTINF:6.000')
      expect(pls).to include('#EXTINF:2.000') # last segment clamps to remainder
      expect(pls).to end_with('#EXT-X-ENDLIST')
    end

    it 'emits the SUBTITLES="subs" group ID for the master STREAM-INF' do
      expect(described_class.stream_inf_subtitle_attr).to eq('SUBTITLES="subs"')
    end

    it 'builds extract args with seek + map + webvtt encoder' do
      args = described_class.extract_args(input_path: '/x.mkv', stream_index: 1,
                                          output_path: '/tmp/out.vtt', start: 60, duration: 5)
      expect(args).to include('-ss', '60')
      expect(args).to include('-t', '5')
      expect(args).to include('-map', '0:s:1')
      expect(args).to include('-c:s', 'webvtt')
    end
  end

  describe 'EncodingHelper integration' do
    let(:caps) do
      Class.new do
        def supports_encoder?(name) %w[libx264 libx265 aac].include?(name) end
        def supports_filter?(_) true end
        def supports_hwaccel?(_) false end
        def supports_decoder?(_) true end
      end.new
    end

    it 'inserts rotation transpose into the -vf chain for portrait video' do
      job = make_job(stream: video_stream(rotation: 90))
      args = Jellyfin::Encoding::EncodingHelper.command_line_arguments(
        job, playlist_path: '/tmp/p.m3u8', segment_template: '/tmp/%d.ts', capabilities: caps
      )
      vf = args[args.index('-vf') + 1]
      expect(vf).to include('transpose=1')
      expect(args).to include('-metadata:s:v:0', 'rotate=0')
    end

    it 'adds -probesize before -i' do
      job = make_job
      args = Jellyfin::Encoding::EncodingHelper.command_line_arguments(
        job, playlist_path: '/tmp/p.m3u8', segment_template: '/tmp/%d.ts', capabilities: caps
      )
      probe_idx = args.index('-probesize')
      i_idx = args.index('-i')
      expect(probe_idx).to be < i_idx
    end

    it 'adds HDR10+ SEI params to -x265-params for HDR10+ sources' do
      stream = video_stream(codec: 'hevc', pixel_format: 'yuv420p10le', bit_depth: 10,
                            video_range_type: 'HDR10', hdr10plus_present: true,
                            color_primaries: 'bt2020', color_transfer: 'smpte2084',
                            color_space: 'bt2020nc')
      job = make_job(stream: stream)
      job.instance_variable_set(:@output_video_codec, 'h265')
      job.options.enable_tonemapping = false
      args = Jellyfin::Encoding::EncodingHelper.command_line_arguments(
        job, playlist_path: '/tmp/p.m3u8', segment_template: '/tmp/%d.ts', capabilities: caps
      )
      x265 = args[args.index('-x265-params') + 1]
      expect(x265).to include('dhdr10-opt=1')
    end
  end
end
