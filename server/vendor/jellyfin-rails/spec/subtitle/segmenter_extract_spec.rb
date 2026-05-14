require 'spec_helper'
require 'jellyfin/subtitle/segmenter'

RSpec.describe Jellyfin::Subtitle::Segmenter do
  # Regression: extract_to used `-map "0:s:#{stream_index}"`, which addresses
  # the Nth SUBTITLE stream (0-indexed inside the subtitle group). Callers
  # pass the GLOBAL stream index from ffprobe (`stream.index`), so on a file
  # with 1 video + 3 audio + 3 subtitle streams, the first subtitle's global
  # index is 4 — and `-map 0:s:4` asked ffmpeg for the FIFTH subtitle, which
  # doesn't exist. extract_to returned false, segmenter returned nil, and
  # WebvttSubsController#index served 404. Upstream Jellyfin uses absolute
  # stream selectors (`0:n`) everywhere subtitle extraction is invoked.
  describe '#extract_to' do
    it 'invokes ffmpeg with `-map 0:N` (absolute index), not `-map 0:s:N`' do
      segmenter = described_class.new(ffmpeg_path: '/usr/bin/ffmpeg', cache_root: '/tmp/sub-cache')

      # Capture-only stub: Open3.capture3 returns success even if ffmpeg
      # isn't actually present in the test environment.
      received = nil
      stub = lambda do |*args|
        received = args
        [+'', +'', double(success?: true)]
      end
      allow(Open3).to receive(:capture3) { |*a| stub.call(*a) }
      # File.exist? must return true so extract_to returns true.
      out_path = '/tmp/sub-cache/full.vtt'
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(out_path).and_return(true)

      segmenter.send(:extract_to, '/src/movie.mkv', 4, out_path)
      expect(received).to include('-map', '0:4')
      expect(received).not_to include('0:s:4')
    end
  end

  # Safari fetches every `EXT-X-MEDIA:TYPE=SUBTITLES` URI in the master
  # playlist in parallel. Without serialisation each request spawned its
  # own ffmpeg writing to the same `full.vtt`, blocking on the source
  # filesystem and exceeding Safari's stall timeout — Safari aborted the
  # master with MEDIA_ERR_SRC_NOT_SUPPORTED. The lock collapses these
  # into one extraction; concurrent callers wait, then re-read the cache.
  describe 'concurrent extraction is serialised via AsyncKeyedLocker' do
    it 'runs ffmpeg only once for two parallel calls on the same (source, stream)' do
      Dir.mktmpdir do |root|
        source = File.join(root, 'movie.mkv')
        File.write(source, '') # path just needs to exist; ffmpeg is stubbed
        segmenter = described_class.new(ffmpeg_path: '/usr/bin/ffmpeg', cache_root: root)

        ffmpeg_calls = 0
        ffmpeg_in_flight = 0
        max_overlap = 0
        gate = Mutex.new
        allow(Open3).to receive(:capture3) do |*args|
          gate.synchronize do
            ffmpeg_calls += 1
            ffmpeg_in_flight += 1
            max_overlap = [max_overlap, ffmpeg_in_flight].max
          end
          # Write a minimal VTT file at the path ffmpeg would produce so
          # segment() succeeds. Hold the slot long enough that without the
          # lock a second caller would observe it as concurrent.
          out_path = args.last
          File.write(out_path, "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nhi\n")
          sleep 0.05
          gate.synchronize { ffmpeg_in_flight -= 1 }
          [+'', +'', double(success?: true)]
        end

        results = []
        threads = 3.times.map do
          Thread.new do
            results << segmenter.segment(source_path: source, stream_index: 0,
                                         segment_length: 6)
          end
        end
        threads.each(&:join)

        expect(results.compact.size).to eq(3)
        expect(ffmpeg_calls).to eq(1) # the lock collapses 3 → 1
        expect(max_overlap).to eq(1)  # never more than one extraction in flight
      end
    end
  end
end
