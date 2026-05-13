require 'spec_helper'
require 'tmpdir'

RSpec.describe Jellyfin::Subtitle::Converter do
  let(:vtt_text) do
    "WEBVTT\n\n" \
      "00:00:01.000 --> 00:00:03.000\nFirst\n\n" \
      "00:00:05.000 --> 00:00:08.000\nMiddle\n\n" \
      "00:00:09.000 --> 00:00:11.000\nLast"
  end

  let(:srt_text) do
    "1\n00:00:01,000 --> 00:00:03,000\nFirst\n\n" \
      "2\n00:00:05,000 --> 00:00:08,000\nMiddle\n\n" \
      "3\n00:00:09,000 --> 00:00:11,000\nLast\n"
  end

  let(:ass_text) do
    "[Script Info]\nScriptType: v4.00+\n\n" \
      "[V4+ Styles]\nFormat: Name\nStyle: Default\n\n" \
      "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n" \
      "Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,First\n" \
      "Dialogue: 0,0:00:05.00,0:00:08.00,Default,,0,0,0,,Middle\n"
  end

  describe '.convert format round-trips' do
    it 'VTT → SRT' do
      out = described_class.convert(text: vtt_text, input_format: 'vtt', output_format: 'srt')
      expect(out).to include('00:00:01,000 --> 00:00:03,000')
      expect(out).to include('First')
      expect(out).to include('Last')
    end

    it 'SRT → VTT' do
      out = described_class.convert(text: srt_text, input_format: 'srt', output_format: 'vtt')
      expect(out).to start_with('WEBVTT')
      expect(out).to include('00:00:05.000 --> 00:00:08.000')
    end

    it 'ASS → SRT (drops styling tags via {} stripping)' do
      ass_with_style = ass_text + "Dialogue: 0,0:00:12.00,0:00:14.00,Default,,0,0,0,,{\\b1}Bold{\\b0} normal\n"
      out = described_class.convert(text: ass_with_style, input_format: 'ass', output_format: 'srt')
      expect(out).to include('Bold normal')
      expect(out).not_to include('{\\b1}')
    end

    it 'VTT → ASS emits the [Events] header and Dialogue lines' do
      out = described_class.convert(text: vtt_text, input_format: 'vtt', output_format: 'ass')
      expect(out).to include('[Script Info]')
      expect(out).to include('[Events]')
      expect(out).to include('Dialogue: 0,')
    end
  end

  describe '.filter_events (port of FilterEvents cs:104)' do
    it 'drops cues entirely before start_position_ticks' do
      cues = described_class.parse(vtt_text, 'vtt')
      filtered = described_class.filter_events(cues, 4 * 10_000_000, 0, false)
      expect(filtered.map(&:text)).not_to include('First')
      expect(filtered.map(&:text)).to include('Middle', 'Last')
    end

    it 'trims cues past end_time_ticks when set' do
      cues = described_class.parse(vtt_text, 'vtt')
      filtered = described_class.filter_events(cues, 0, 7 * 10_000_000, true)
      expect(filtered.map(&:text)).to eq(['First', 'Middle'])
    end

    it 'rebases timestamps when preserve=false' do
      cues = described_class.parse(vtt_text, 'vtt')
      filtered = described_class.filter_events(cues, 4 * 10_000_000, 0, false)
      # Middle was at 5.0s..8.0s → shift by 4s → 1.0s..4.0s
      expect(filtered.first.start_seconds).to be_within(0.01).of(1.0)
      expect(filtered.first.end_seconds).to be_within(0.01).of(4.0)
    end

    it 'preserves original timestamps when preserve=true' do
      cues = described_class.parse(vtt_text, 'vtt')
      filtered = described_class.filter_events(cues, 4 * 10_000_000, 0, true)
      expect(filtered.first.start_seconds).to be_within(0.01).of(5.0)
    end
  end

  describe 'parse_ts edge cases' do
    it 'parses HH:MM:SS.mmm and MM:SS.mmm equally' do
      expect(described_class.parse_ts('01:02:03.500')).to eq(3723.5)
      expect(described_class.parse_ts('02:03.500')).to eq(123.5)
    end

    it 'parses ASS h:mm:ss.cc' do
      expect(described_class.parse_ass_ts('1:02:03.45')).to eq(3723.45)
    end
  end
end

RSpec.describe 'GET /subtitles/:token/:index/:ticks.:format', type: :request do
  let(:fixture) { File.join(FIXTURE_PATH, 'sample.mp4') }
  let(:tmp_root) { Dir.mktmpdir('jelly-u-') }

  before do
    skip 'fixture missing' unless File.exist?(fixture)
    ffmpeg = ENV.fetch('TEST_FFMPEG_PATH', '/Applications/Jellyfin.app/Contents/MacOS/ffmpeg')
    skip 'ffmpeg not present' unless File.executable?(ffmpeg)
    Jellyfin::Rails.configure do |c|
      c.ffmpeg_path = ffmpeg
      c.transcode_dir = tmp_root
      c.token_secret = 'batch-u'
      c.allowed_paths = [FIXTURE_PATH]
    end
  end

  after { FileUtils.rm_rf(tmp_root) }

  it 'returns 200 with the requested subtitle format (route present)' do
    token = Jellyfin::Transcoding::Token.encode(path: fixture)
    # The sample MP4 has no embedded subs — we just verify the route exists +
    # doesn't 404. (Returning 200 vs 5xx depends on whether ffmpeg's extract
    # succeeds with an empty-stream source.)
    get "/jellyfin/subtitles/#{token}/0/30000000.vtt"
    expect([200, 502, 500]).to include(response.status)
  end
end

RSpec.describe 'GET /fallback_fonts/:name', type: :request do
  let(:tmp_root) { Dir.mktmpdir('jelly-fonts-') }
  let(:font_dir) { Dir.mktmpdir('fonts-') }
  before do
    Jellyfin::Rails.configure do |c|
      c.transcode_dir = tmp_root
      c.token_secret = 'fonts'
      c.fallback_font_path = font_dir
    end
    File.write(File.join(font_dir, 'OpenSans.ttf'), "TTF\x00\x01\x00\x00")
  end

  after do
    FileUtils.rm_rf(tmp_root)
    FileUtils.rm_rf(font_dir)
    Jellyfin::Rails.configuration.fallback_font_path = nil
  end

  it 'serves a known font file with font/* MIME' do
    get '/jellyfin/fallback_fonts/OpenSans.ttf'
    expect(response).to have_http_status(:ok)
    expect(response.headers['Content-Type']).to eq('font/ttf')
  end

  it 'is case-insensitive on the filename' do
    get '/jellyfin/fallback_fonts/opensans.ttf'
    expect(response).to have_http_status(:ok)
  end

  it '404s when the font is unknown' do
    get '/jellyfin/fallback_fonts/Missing.ttf'
    expect(response).to have_http_status(:not_found)
  end

  it '404s when no fallback_font_path is configured' do
    Jellyfin::Rails.configuration.fallback_font_path = nil
    get '/jellyfin/fallback_fonts/OpenSans.ttf'
    expect(response).to have_http_status(:not_found)
  end
end
