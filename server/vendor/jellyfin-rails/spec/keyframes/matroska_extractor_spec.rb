require 'spec_helper'
require 'tempfile'
require 'jellyfin/keyframes/matroska_extractor'

RSpec.describe Jellyfin::Keyframes::MatroskaExtractor do
  # --- EBML construction helpers ------------------------------------
  #
  # Builds the smallest MKV byte sequence the extractor needs to walk
  # to a result. We compose:
  #
  #   EBML header        (skipped)
  #   Segment
  #     SeekHead         (with entries → Info, Tracks, Cues)
  #     Info             (TimestampScale, Duration)
  #     Tracks           (TrackEntry → Video)
  #     Cues             (CuePoints → CueTime + CueTrackPositions/CueTrack)
  #
  # SeekHead offsets are relative to the start of the Segment's DATA
  # area (after Segment's ID+size). We compute them by laying out the
  # children first and tracking each child's start position.

  # Pack a multi-byte integer as raw big-endian bytes (no VINT marker).
  def be_bytes(value, len)
    out = String.new(encoding: Encoding::ASCII_8BIT)
    (len - 1).downto(0) { |i| out << ((value >> (i * 8)) & 0xFF) }
    out
  end

  # EBML element IDs already include their VINT marker bit, so we just
  # emit them as a fixed byte sequence determined by their bit width.
  ELEMENT_ID_LENGTHS = {
    0x1A45DFA3 => 4,  # EBML
    0x18538067 => 4,  # Segment
    0x114D9B74 => 4,  # SeekHead
    0x4DBB     => 2,  # Seek
    0x53AB     => 2,  # SeekID
    0x53AC     => 2,  # SeekPosition
    0x1549A966 => 4,  # Info
    0x2AD7B1   => 3,  # TimestampScale
    0x4489     => 2,  # Duration
    0x1654AE6B => 4,  # Tracks
    0xAE       => 1,  # TrackEntry
    0xD7       => 1,  # TrackNumber
    0x83       => 1,  # TrackType
    0x1C53BB6B => 4,  # Cues
    0xBB       => 1,  # CuePoint
    0xB3       => 1,  # CueTime
    0xB7       => 1,  # CueTrackPositions
    0xF7       => 1   # CueTrack
  }.freeze

  def emit_id(id)
    len = ELEMENT_ID_LENGTHS.fetch(id)
    be_bytes(id, len)
  end

  # VINT size encoded into a fixed 4-byte form. Marker bit is `0x10` at
  # position 4 (i.e., the high nibble of byte 0 reads `0001`), with the
  # remaining 28 bits carrying the size payload. Sufficient for tests.
  def emit_size(size)
    raise 'size too large for 4-byte VINT' if size >= (1 << 28)
    out = String.new(encoding: Encoding::ASCII_8BIT)
    out << (0x10 | ((size >> 24) & 0x0F))
    out << ((size >> 16) & 0xFF)
    out << ((size >>  8) & 0xFF)
    out << (size         & 0xFF)
    out
  end

  def element(id, content)
    emit_id(id) + emit_size(content.bytesize) + content
  end

  def uint_element(id, value, len)
    element(id, be_bytes(value, len))
  end

  def float64_element(id, value)
    element(id, [ value ].pack('G'))
  end

  # ----- Compose the file -----

  let(:timestamp_scale) { 1_000_000 }  # 1 ms per tick
  let(:duration_raw)    { 30_000.0 }   # 30 s @ 1 ms scale
  let(:video_track)     { 1 }
  let(:cue_times)       { [ 0, 6_000, 12_000, 18_000, 24_000 ] }  # 0,6,12,18,24 s

  def info_block
    element(
      0x1549A966,
      uint_element(0x2AD7B1, timestamp_scale, 4) +
        float64_element(0x4489, duration_raw)
    )
  end

  def tracks_block
    video_entry = element(
      0xAE,
      uint_element(0xD7, video_track, 1) +
        uint_element(0x83, 1, 1) # TrackTypeVideo
    )
    # Audio entry — exercises the "skip non-video track" path.
    audio_entry = element(
      0xAE,
      uint_element(0xD7, 2, 1) +
        uint_element(0x83, 2, 1) # TrackTypeAudio
    )
    element(0x1654AE6B, audio_entry + video_entry)
  end

  def cues_block
    points = cue_times.map do |t|
      element(
        0xBB,
        uint_element(0xB3, t, 4) +
          element(0xB7, uint_element(0xF7, video_track, 1))
      )
    end
    element(0x1C53BB6B, points.join)
  end

  def seek_head_block(info_off:, tracks_off:, cues_off:)
    seek_entry = lambda do |target_id, position|
      element(
        0x4DBB,
        element(0x53AB, emit_id(target_id)) +
          uint_element(0x53AC, position, 4)
      )
    end
    element(
      0x114D9B74,
      seek_entry[0x1549A966, info_off] +
        seek_entry[0x1654AE6B, tracks_off] +
        seek_entry[0x1C53BB6B, cues_off]
    )
  end

  def build_mkv
    info = info_block
    tracks = tracks_block
    cues = cues_block
    # First pass with a placeholder SeekHead to measure its size, then
    # compute real offsets and rebuild. SeekHead size is stable because
    # the entries always encode the offsets as 4-byte uints — so we can
    # avoid the placeholder and just compute upfront.
    seek_head_size = seek_head_block(info_off: 0, tracks_off: 0, cues_off: 0).bytesize
    info_off = seek_head_size
    tracks_off = info_off + info.bytesize
    cues_off = tracks_off + tracks.bytesize
    sh = seek_head_block(info_off: info_off, tracks_off: tracks_off, cues_off: cues_off)
    raise 'seek_head sizing drift' unless sh.bytesize == seek_head_size

    segment_data = sh + info + tracks + cues
    ebml_header = element(0x1A45DFA3, '')
    segment = element(0x18538067, segment_data)
    ebml_header + segment
  end

  def with_mkv_tempfile
    Tempfile.create([ 'mkv-extract', '.mkv' ]) do |f|
      f.binmode
      f.write(build_mkv)
      f.flush
      yield f.path
    end
  end

  describe '.extract' do
    it 'returns nil for a missing path' do
      expect(described_class.extract('/no/such/file.mkv')).to be_nil
    end

    it 'reads keyframe times scaled to seconds from the MKV Cues block' do
      with_mkv_tempfile do |path|
        result = described_class.extract(path)
        expect(result).not_to be_nil
        # cue_times are in ticks at 1ms scale → already integer seconds × 1000.
        # 1ms × 1e-9 ns/ms × ticks-in-ns scaling: ticks * 1e6 / 1e9 = ticks/1000.
        expect(result.keyframe_seconds).to eq([ 0.0, 6.0, 12.0, 18.0, 24.0 ])
        expect(result.duration_seconds).to eq(30.0)
      end
    end

    it 'ignores cue points belonging to non-video tracks' do
      # Swap one cue's track to the audio track. Only the four remaining
      # video cues should make it into the result.
      original_cues = method(:cues_block)
      define_singleton_method(:cues_block) do
        points = cue_times.each_with_index.map do |t, i|
          track = i == 2 ? 2 : video_track # poison cue at index 2
          element(
            0xBB,
            uint_element(0xB3, t, 4) +
              element(0xB7, uint_element(0xF7, track, 1))
          )
        end
        element(0x1C53BB6B, points.join)
      end

      with_mkv_tempfile do |path|
        result = described_class.extract(path)
        expect(result.keyframe_seconds).to eq([ 0.0, 6.0, 18.0, 24.0 ])
      end
    ensure
      define_singleton_method(:cues_block, &original_cues) if original_cues
    end
  end
end
