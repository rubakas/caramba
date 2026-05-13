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
end
