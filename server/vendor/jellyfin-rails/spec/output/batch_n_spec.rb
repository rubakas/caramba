require 'spec_helper'
require 'tmpdir'

RSpec.describe 'Batch N — HLS advanced' do
  describe Jellyfin::Output::HlsEncryption do
    let(:tmp) { Dir.mktmpdir('enc-') }
    after { FileUtils.rm_rf(tmp) }

    it 'generates a 16-byte key + keyinfo file with the right structure' do
      m = described_class.generate!(session_dir: tmp, key_uri: 'http://x/keys/abc.key')
      expect(File.binread(m.key_path).bytesize).to eq(16)
      info = File.read(m.info_path).split("\n")
      expect(info[0]).to eq('http://x/keys/abc.key')
      expect(info[1]).to eq(m.key_path)
      expect(info[2]).to match(/\A[0-9a-f]{32}\z/)
    end

    it 'sets 0600 perms on the key file' do
      m = described_class.generate!(session_dir: tmp, key_uri: 'http://x/k.key')
      stat = File.stat(m.key_path)
      expect(stat.mode & 0o777).to eq(0o600)
    end

    it 'output_args inserts the hls_enc flags when material is present' do
      m = described_class.generate!(session_dir: tmp, key_uri: 'http://x/k.key')
      args = described_class.output_args(m)
      expect(args).to include('-hls_enc', '1')
      expect(args).to include('-hls_enc_key_url', 'http://x/k.key')
      expect(args).to include('-hls_key_info_file', m.info_path)
    end

    it 'output_args returns [] when no material' do
      expect(described_class.output_args(nil)).to eq([])
    end
  end

  describe Jellyfin::Output::LlHls do
    it 'emits fmp4 + partial segment flags' do
      args = described_class.output_args(partial_target: 0.3, segment_length: 4)
      expect(args).to include('-hls_segment_type', 'fmp4')
      expect(args).to include('-hls_part_target', '0.30')
      expect(args).to include('-hls_partial_segments', '1')
    end

    it 'parses _HLS_msn and _HLS_part query params' do
      msn, part = described_class.parse_blocking_hint('_HLS_msn' => '12', '_HLS_part' => '3')
      expect(msn).to eq(12)
      expect(part).to eq(3)
    end

    it 'is empty when no hint is supplied' do
      msn, part = described_class.parse_blocking_hint({})
      expect(msn).to be_nil
      expect(part).to be_nil
    end

    it 'server_control_header includes CAN-BLOCK-RELOAD + PART-HOLD-BACK' do
      line = described_class.server_control_header(part_hold_back: 1.5)
      expect(line).to include('CAN-BLOCK-RELOAD=YES')
      expect(line).to include('PART-HOLD-BACK=1.500')
    end

    it 'preload_hint formats URI properly' do
      hint = described_class.preload_hint(uri: 'next.part.m4s')
      expect(hint).to eq('#EXT-X-PRELOAD-HINT:TYPE=PART,URI="next.part.m4s"')
    end

    it 'part_line includes INDEPENDENT=YES when set' do
      line = described_class.part_line(uri: 'p.m4s', duration: 0.2, independent: true)
      expect(line).to include('DURATION=0.200')
      expect(line).to include('INDEPENDENT=YES')
    end
  end

  describe Jellyfin::Output::Cmaf do
    it 'emits dash muxer args with HLS playlist generation enabled' do
      args = described_class.output_args(
        manifest_path: '/tmp/master.mpd',
        segment_dir: '/tmp',
        segment_length: 4
      )
      expect(args).to include('-f', 'dash')
      expect(args).to include('-hls_playlist', '1')
      expect(args).to include('-hls_master_name', 'master.m3u8')
    end

    it 'lists segments matching the representation pattern' do
      tmp = Dir.mktmpdir
      File.write(File.join(tmp, '0-00001.m4s'), '')
      File.write(File.join(tmp, '0-00002.m4s'), '')
      File.write(File.join(tmp, '1-00001.m4s'), '')
      expect(described_class.list_segments(tmp, representation: '0').map { |s| File.basename(s) })
        .to eq(['0-00001.m4s', '0-00002.m4s'])
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe Jellyfin::Subtitle::ClosedCaptions do
    def stream(closed_captions: 0, has_cc: false)
      Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264',
        closed_captions: closed_captions, has_closed_captions: has_cc)
    end

    it 'detects via the closed_captions count (mpeg2 path)' do
      expect(described_class.present?(stream(closed_captions: 1))).to be(true)
    end

    it 'detects via has_closed_captions side-data flag (h264/hevc path)' do
      expect(described_class.present?(stream(has_cc: true))).to be(true)
    end

    it 'is false when neither flag is set' do
      expect(described_class.present?(stream)).to be(false)
    end

    it 'emits #EXT-X-MEDIA TYPE=CLOSED-CAPTIONS with INSTREAM-ID' do
      line = described_class.master_media_line(instream: 'CC1', name: 'English', language: 'en')
      expect(line).to include('TYPE=CLOSED-CAPTIONS')
      expect(line).to include('INSTREAM-ID="CC1"')
      expect(line).to include('LANGUAGE="en"')
    end

    it 'stream_inf attr references the cc group' do
      expect(described_class.stream_inf_cc_attr).to eq('CLOSED-CAPTIONS="cc"')
    end

    it 'preserve_args returns -a53cc 1' do
      expect(described_class.preserve_args).to eq(['-a53cc', '1'])
    end
  end

  describe Jellyfin::Encoding::EncodingHelper, 'HLS encryption integration' do
    it 'HlsEncryption.output_args splices the right flags into ffmpeg args' do
      tmp = Dir.mktmpdir
      m = Jellyfin::Output::HlsEncryption.generate!(session_dir: tmp, key_uri: 'http://x/k.key')
      args = Jellyfin::Output::HlsEncryption.output_args(m)
      expect(args).to include('-hls_enc', '1')
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end
end
