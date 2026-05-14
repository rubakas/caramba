module Jellyfin
  module Keyframes
    # Extracts video keyframe positions from a Matroska (.mkv) file via
    # its Cues index. Reading the Cues is O(keyframes), milliseconds for
    # any reasonably-sized file regardless of total runtime — we never
    # scan packets, only the metadata block at the end of the file.
    #
    # Mirrors upstream
    # jellyfin/src/Jellyfin.MediaEncoding.Keyframes/Matroska/MatroskaKeyframeExtractor.cs.
    #
    # Returns a Result struct with `duration_seconds` and
    # `keyframe_seconds` (sorted ascending). Returns nil if the file
    # isn't an MKV, is missing Cues, or is malformed.
    module MatroskaExtractor
      # Element IDs (full VINTs with marker bits preserved — that's how
      # MKV/EBML identifies elements in stored byte form).
      EBML_HEADER            = 0x1A45DFA3
      SEGMENT                = 0x18538067
      SEEK_HEAD              = 0x114D9B74
      SEEK                   = 0x4DBB
      SEEK_ID                = 0x53AB
      SEEK_POSITION          = 0x53AC
      INFO                   = 0x1549A966
      TIMESTAMP_SCALE        = 0x2AD7B1
      DURATION               = 0x4489
      TRACKS                 = 0x1654AE6B
      TRACK_ENTRY            = 0xAE
      TRACK_NUMBER           = 0xD7
      TRACK_TYPE             = 0x83
      TRACK_TYPE_VIDEO       = 1
      CUES                   = 0x1C53BB6B
      CUE_POINT              = 0xBB
      CUE_TIME               = 0xB3
      CUE_TRACK_POSITIONS    = 0xB7
      CUE_TRACK              = 0xF7

      Result = Struct.new(:duration_seconds, :keyframe_seconds)

      module_function

      def extract(path)
        return nil unless path && File.file?(path)
        File.open(path, 'rb') do |io|
          Reader.new(io).extract
        end
      rescue StandardError
        nil
      end

      # Stateful walker over an EBML stream. Kept private so the extract
      # surface stays a free function.
      class Reader
        def initialize(io)
          @io = io
        end

        def extract
          return nil unless skip_ebml_header_and_enter_segment
          segment_data_start = @io.pos

          offsets = read_seek_head(segment_data_start)
          return nil unless offsets[:info] && offsets[:tracks] && offsets[:cues]

          info = read_info(segment_data_start + offsets[:info])
          scale_ns = info[:timestamp_scale]
          return nil unless scale_ns

          video_track_no = read_video_track_number(segment_data_start + offsets[:tracks])
          return nil unless video_track_no

          cue_times = read_cues(segment_data_start + offsets[:cues], video_track_no)
          return nil if cue_times.empty?

          duration_raw = info[:duration].to_f
          MatroskaExtractor::Result.new(
            duration_raw * scale_ns / 1_000_000_000.0,
            cue_times.map { |t| t * scale_ns / 1_000_000_000.0 }.sort
          )
        end

        private

        def skip_ebml_header_and_enter_segment
          @io.seek(0)
          id, size = read_element_header
          return false unless id == EBML_HEADER && size
          @io.seek(size, IO::SEEK_CUR)
          id, _size = read_element_header
          id == SEGMENT
        end

        # Walks top-level Segment children until SeekHead is found, then
        # extracts the entries pointing at Info / Tracks / Cues. Offsets
        # in MKV SeekHead are relative to the start of the Segment's
        # data area (`segment_start` here).
        def read_seek_head(segment_start)
          result = { info: nil, tracks: nil, cues: nil }
          @io.seek(segment_start)
          loop do
            id, size = read_element_header
            return result if id.nil? || size.nil?
            if id == SEEK_HEAD
              read_seek_head_entries(size, result)
              return result
            end
            @io.seek(size, IO::SEEK_CUR)
          end
        end

        def read_seek_head_entries(seek_head_size, result)
          end_pos = @io.pos + seek_head_size
          while @io.pos < end_pos
            id, size = read_element_header
            break if id.nil? || size.nil?
            if id == SEEK
              entry_end = @io.pos + size
              seek_id = nil
              seek_pos = nil
              while @io.pos < entry_end
                child_id, child_size = read_element_header
                break if child_id.nil? || child_size.nil?
                case child_id
                when SEEK_ID       then seek_id  = read_uint(child_size)
                when SEEK_POSITION then seek_pos = read_uint(child_size)
                else                    @io.seek(child_size, IO::SEEK_CUR)
                end
              end
              case seek_id
              when INFO   then result[:info]   ||= seek_pos
              when TRACKS then result[:tracks] ||= seek_pos
              when CUES   then result[:cues]   ||= seek_pos
              end
            else
              @io.seek(size, IO::SEEK_CUR)
            end
          end
        end

        def read_info(pos)
          @io.seek(pos)
          id, size = read_element_header
          return {} unless id == INFO && size
          end_pos = @io.pos + size
          out = { timestamp_scale: nil, duration: nil }
          while @io.pos < end_pos
            child_id, child_size = read_element_header
            break if child_id.nil? || child_size.nil?
            case child_id
            when TIMESTAMP_SCALE then out[:timestamp_scale] = read_uint(child_size)
            when DURATION        then out[:duration]        = read_float(child_size)
            else                       @io.seek(child_size, IO::SEEK_CUR)
            end
          end
          out
        end

        def read_video_track_number(pos)
          @io.seek(pos)
          id, size = read_element_header
          return nil unless id == TRACKS && size
          end_pos = @io.pos + size
          while @io.pos < end_pos
            child_id, child_size = read_element_header
            break if child_id.nil? || child_size.nil?
            if child_id == TRACK_ENTRY
              entry_end = @io.pos + child_size
              track_number = nil
              track_type = nil
              while @io.pos < entry_end
                gid, gsize = read_element_header
                break if gid.nil? || gsize.nil?
                case gid
                when TRACK_NUMBER then track_number = read_uint(gsize)
                when TRACK_TYPE   then track_type   = read_uint(gsize)
                else                   @io.seek(gsize, IO::SEEK_CUR)
                end
              end
              return track_number if track_type == TRACK_TYPE_VIDEO
            else
              @io.seek(child_size, IO::SEEK_CUR)
            end
          end
          nil
        end

        def read_cues(pos, video_track_no)
          @io.seek(pos)
          id, size = read_element_header
          return [] unless id == CUES && size
          end_pos = @io.pos + size
          out = []
          while @io.pos < end_pos
            child_id, child_size = read_element_header
            break if child_id.nil? || child_size.nil?
            if child_id == CUE_POINT
              cp_end = @io.pos + child_size
              cue_time = nil
              for_video = false
              while @io.pos < cp_end
                gid, gsize = read_element_header
                break if gid.nil? || gsize.nil?
                case gid
                when CUE_TIME
                  cue_time = read_uint(gsize)
                when CUE_TRACK_POSITIONS
                  tp_end = @io.pos + gsize
                  while @io.pos < tp_end
                    ggid, ggsize = read_element_header
                    break if ggid.nil? || ggsize.nil?
                    if ggid == CUE_TRACK
                      for_video = true if read_uint(ggsize) == video_track_no
                    else
                      @io.seek(ggsize, IO::SEEK_CUR)
                    end
                  end
                else
                  @io.seek(gsize, IO::SEEK_CUR)
                end
              end
              out << cue_time if for_video && cue_time
            else
              @io.seek(child_size, IO::SEEK_CUR)
            end
          end
          out
        end

        # --- EBML primitives ---

        def read_element_header
          id = read_vint_id
          return [ nil, nil ] if id.nil?
          size = read_vint_size
          [ id, size ]
        end

        # VINT element ID — full byte sequence kept (including the
        # length-marker bit), since IDs are matched against the canonical
        # constants above which carry the marker.
        def read_vint_id
          first = @io.read(1)
          return nil if first.nil? || first.empty?
          b = first.unpack1('C')
          return nil if b.zero?
          len = vint_length(b)
          return nil if len.nil?
          value = b
          if len > 1
            rest = @io.read(len - 1)
            return nil if rest.nil? || rest.bytesize != len - 1
            rest.each_byte { |v| value = (value << 8) | v }
          end
          value
        end

        # VINT size — same encoding as ID but the leading marker bit is
        # masked off so the returned integer is the literal data length.
        def read_vint_size
          first = @io.read(1)
          return nil if first.nil? || first.empty?
          b = first.unpack1('C')
          return nil if b.zero?
          len = vint_length(b)
          return nil if len.nil?
          value = b & ((1 << (8 - len)) - 1)
          if len > 1
            rest = @io.read(len - 1)
            return nil if rest.nil? || rest.bytesize != len - 1
            rest.each_byte { |v| value = (value << 8) | v }
          end
          value
        end

        def vint_length(first_byte)
          mask = 0x80
          (1..8).each do |i|
            return i if (first_byte & mask) != 0
            mask >>= 1
          end
          nil
        end

        def read_uint(n)
          return 0 if n.zero?
          bytes = @io.read(n)
          return 0 if bytes.nil? || bytes.bytesize != n
          value = 0
          bytes.each_byte { |v| value = (value << 8) | v }
          value
        end

        def read_float(n)
          case n
          when 4 then @io.read(4).to_s.unpack1('g').to_f
          when 8 then @io.read(8).to_s.unpack1('G').to_f
          else
            @io.seek(n, IO::SEEK_CUR)
            0.0
          end
        end
      end
    end
  end
end
