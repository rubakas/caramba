require 'spec_helper'

RSpec.describe Jellyfin::Output::CodecString do
  describe '.for' do
    it 'produces a typical AVC + AAC string for a 1080p High 4.0 source' do
      s = described_class.for(video_codec: 'h264', audio_codec: 'aac', profile: 'high', level: 4.0)
      expect(s).to eq('avc1.640028,mp4a.40.2')
    end

    it 'encodes level 4.1 as 0x29 (41 decimal → 29 hex)' do
      s = described_class.for(video_codec: 'h264', audio_codec: 'aac', profile: 'high', level: 4.1)
      expect(s).to eq('avc1.640029,mp4a.40.2')
    end

    it 'emits hvc1 for HEVC main10 per Apple HLS spec, with level_idc as-is' do
      # Apple's HLS Authoring Spec requires `hvc1.*` in CODECS when the
      # fMP4 sample entry uses the `hvc1` tag — which our HLS muxer
      # configures via `-tag:v hvc1`. Mismatch makes Safari reject the
      # master with MEDIA_ERR_DECODE.
      #
      # HEVC codec-string level is the raw level_idc value (e.g. 120 =
      # HEVC Level 4.0, encoded as `L120`). Callers (master_playlist_builder)
      # pass `video_stream.level.to_i` directly. Mirrors upstream
      # HlsCodecStringHelpers.cs:223-225.
      s = described_class.for(video_codec: 'hevc', audio_codec: 'aac', profile: 'main10', level: 120)
      expect(s).to eq('hvc1.2.4.L120.B0,mp4a.40.2')
    end

    it 'matches HEVC `Main 10` profile name with a space (ffprobe form)' do
      # ffprobe reports HEVC 10-bit content as `Main 10` (with a space);
      # RFC 6381 / Caramba code paths often use `main10` (no space).
      # The codec-string emitter must accept both. Upstream Jellyfin's
      # HlsCodecStringHelpers.cs:213 explicitly matches both forms.
      s = described_class.for(video_codec: 'hevc', audio_codec: 'aac', profile: 'Main 10', level: 120)
      expect(s).to start_with('hvc1.2.4.L120.')
    end

    it 'maps AC-3 / E-AC-3 to their RFC 6381 names' do
      expect(described_class.audio_string('ac3')).to eq('ac-3')
      expect(described_class.audio_string('eac3')).to eq('ec-3')
    end

    it 'omits audio segment when codec is unknown' do
      s = described_class.for(video_codec: 'h264', audio_codec: 'unknown', profile: 'high', level: 4.0)
      expect(s).not_to include(',')
    end
  end
end
