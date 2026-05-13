require 'spec_helper'

RSpec.describe 'Batch O — Operations' do
  describe Jellyfin::Transcoding::ProgressBroadcaster do
    before { described_class.reset! }

    it 'fires subscriber blocks with snapshots from TranscodeManager' do
      job = double('job', progress_snapshot: { frame: 100, fps: 24.0 })
      manager = double('manager', find: job)
      allow(Jellyfin::Transcoding::TranscodeManager).to receive(:instance).and_return(manager)
      stub_const('Jellyfin::Transcoding::ProgressBroadcaster::INTERVAL', 0.05)

      received = []
      sub_id = described_class.instance.subscribe('job-1') { |s| received << s }
      sleep 0.2
      described_class.instance.unsubscribe('job-1', sub_id)
      expect(received).not_to be_empty
      expect(received.first).to include(frame: 100)
    end

    it 'unsubscribing the last listener stops the polling thread' do
      manager = double('manager', find: double(progress_snapshot: {}))
      allow(Jellyfin::Transcoding::TranscodeManager).to receive(:instance).and_return(manager)
      stub_const('Jellyfin::Transcoding::ProgressBroadcaster::INTERVAL', 0.02)

      sub_id = described_class.instance.subscribe('job-2') { }
      sleep 0.05
      described_class.instance.unsubscribe('job-2', sub_id)
      sleep 0.05
      threads = described_class.instance.instance_variable_get(:@threads)
      expect(threads).to be_empty
    end
  end

  describe Jellyfin::Drm::Cenc do
    it 'generates a fresh material with 128-bit key + KID' do
      m = described_class.generate
      expect(m.key_hex.length).to eq(32)
      expect(m.kid_hex.length).to eq(32)
      expect(m.scheme).to eq('cenc-aes-ctr')
    end

    it 'outputs the right ffmpeg encryption args' do
      m = described_class.generate(scheme: 'cbcs')
      args = described_class.output_args(m)
      expect(args).to include('-encryption_scheme', 'cbcs')
      expect(args).to include('-encryption_key', m.key_hex)
      expect(args).to include('-encryption_kid', m.kid_hex)
    end

    it 'returns [] when no material is supplied' do
      expect(described_class.output_args(nil)).to eq([])
    end
  end

  describe Jellyfin::Drm::Pssh do
    let(:kid) { ['00112233445566778899aabbccddeeff'].pack('H*') }

    it 'builds a Widevine v1 PSSH box with the right magic + system ID' do
      box = described_class.box(system: :widevine, kids: [kid])
      # Type field starts at byte offset 4.
      expect(box[4, 4]).to eq('pssh')
      # Version is 1.
      expect(box[8].unpack1('C')).to eq(1)
      # System ID is the Widevine UUID (binary).
      expect(box[12, 16].unpack1('H*')).to eq('edef8ba979d64acea3c827dcd51d21ed')
    end

    it 'supports PlayReady and FairPlay system IDs' do
      expect(described_class.box(system: :playready, kids: [kid])[12, 16].unpack1('H*'))
        .to eq('9a04f07998404286ab92e65be0885f95')
      expect(described_class.box(system: :fairplay, kids: [kid])[12, 16].unpack1('H*'))
        .to eq('94ce86fb07ff4f43adb893d2fa968ca2')
    end

    it 'base64-encodes the PSSH box for MPD inclusion' do
      b64 = described_class.base64(system: :widevine, kids: [kid])
      decoded = Base64.strict_decode64(b64)
      expect(decoded[4, 4]).to eq('pssh')
    end
  end

  describe Jellyfin::Drm::LicenseUrl do
    it 'emits an MPD ContentProtection element with the right schemeIdUri' do
      xml = described_class.mpd_content_protection(
        system: :widevine, license_url: 'https://license.example/widevine',
        pssh_base64: 'AAAA'
      )
      expect(xml).to include('urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed')
      expect(xml).to include('<cenc:pssh>AAAA</cenc:pssh>')
      expect(xml).to include('<dashif:Laurl>https://license.example/widevine</dashif:Laurl>')
    end

    it 'emits an HLS EXT-X-SESSION-KEY with the FairPlay keyformat' do
      line = described_class.hls_session_key(
        system: :fairplay, license_url: 'https://license.example/fp'
      )
      expect(line).to start_with('#EXT-X-SESSION-KEY:')
      expect(line).to include('METHOD=SAMPLE-AES')
      expect(line).to include('KEYFORMAT="com.apple.streamingkeydelivery"')
      expect(line).to include('URI="https://license.example/fp"')
    end

    it 'uses ClearKey identity keyformat for clearkey' do
      line = described_class.hls_session_key(system: :clearkey, license_url: 'https://x/keys/y.bin')
      expect(line).to include('KEYFORMAT="identity"')
    end
  end

  describe Jellyfin::Drm::Kms do
    before { described_class.reset! }

    it 'default Local KMS returns Material with a stable KID per item' do
      kms = described_class.default
      a1 = kms.acquire_key('item-1')
      a2 = kms.acquire_key('item-1')
      b  = kms.acquire_key('item-2')
      expect(a1.kid_hex).to eq(a2.kid_hex)
      expect(a1.kid_hex).not_to eq(b.kid_hex)
    end

    it 'registry override returns the registered KMS' do
      custom = Class.new do
        def acquire_key(_, scheme:); Jellyfin::Drm::Cenc::Material.new(key_hex: 'k', kid_hex: 'i', scheme: scheme); end
        def license_url(_, system:); "https://custom/#{system}"; end
      end.new
      described_class.register(:widevine, custom)
      expect(described_class.for(:widevine)).to equal(custom)
    end
  end
end
