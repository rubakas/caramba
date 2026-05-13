module Jellyfin
  module Subtitle
    # Port of MediaBrowser.MediaEncoding/Subtitles/SubtitleEncoder.cs:
    #   - ConvertSubtitles (cs:73)
    #   - FilterEvents (cs:104)
    #   - GetWriter / parser dispatch
    #
    # Reads subtitle text in one format, filters cues by [start, end] ticks,
    # optionally shifts timestamps, and writes another format. Supports the
    # three formats Jellyfin's parsers + writers handle: SRT, WebVTT, ASS/SSA.
    module Converter
      TICKS_PER_SECOND = 10_000_000

      # Format strings match SubtitleFormatExtensions.cs in upstream.
      FORMATS = %w[srt vtt ass ssa].freeze

      Cue = Struct.new(:start_seconds, :end_seconds, :text, keyword_init: true)

      module_function

      # Mirrors SubtitleEncoder.ConvertSubtitles (cs:73).
      def convert(text:, input_format:, output_format:,
                  start_time_ticks: 0, end_time_ticks: 0,
                  preserve_original_timestamps: false)
        cues = parse(text, input_format)
        cues = filter_events(cues, start_time_ticks, end_time_ticks,
                             preserve_original_timestamps)
        write(cues, output_format)
      end

      # Port of FilterEvents (cs:104). Drops cues that ended before
      # `start_position_ticks`, optionally trims past `end_time_ticks`, and
      # rebases timestamps unless `preserve_original_timestamps` is true.
      def filter_events(cues, start_position_ticks, end_time_ticks, preserve_original_timestamps)
        start_s = start_position_ticks.to_f / TICKS_PER_SECOND
        end_s   = end_time_ticks.to_f / TICKS_PER_SECOND

        out = cues.drop_while do |c|
          (c.start_seconds - start_s) < 0 && (c.end_seconds - start_s) < 0
        end
        out = out.take_while { |c| c.start_seconds <= end_s } if end_time_ticks.positive?

        unless preserve_original_timestamps
          out = out.map do |c|
            Cue.new(
              start_seconds: [0, c.start_seconds - start_s].max,
              end_seconds:   [0, c.end_seconds   - start_s].max,
              text: c.text
            )
          end
        end
        out
      end

      # Format dispatch — mirrors SubtitleEncoder.GetParser.
      def parse(text, format)
        case format.to_s.downcase
        when 'srt'             then parse_srt(text)
        when 'vtt', 'webvtt'   then parse_vtt(text)
        when 'ass', 'ssa'      then parse_ass(text)
        else raise ArgumentError, "unknown subtitle format: #{format}"
        end
      end

      # Format dispatch — mirrors SubtitleEncoder.GetWriter.
      def write(cues, format)
        case format.to_s.downcase
        when 'srt'             then write_srt(cues)
        when 'vtt', 'webvtt'   then write_vtt(cues)
        when 'ass', 'ssa'      then write_ass(cues)
        else raise ArgumentError, "unknown subtitle format: #{format}"
        end
      end

      # ---- SRT (SubRip) ---------------------------------------------------

      def parse_srt(text)
        # SRT cue format:
        #   <index>
        #   HH:MM:SS,mmm --> HH:MM:SS,mmm
        #   <text lines>
        #   <blank line>
        cues = []
        text.split(/\r?\n\r?\n/).each do |block|
          lines = block.split(/\r?\n/).reject(&:empty?)
          # First line is the cue index (we ignore); second is the timestamp.
          ts_line = lines.find { |l| l.include?('-->') }
          next unless ts_line
          start_ts, end_ts = ts_line.split('-->').map(&:strip)
          # SRT uses comma as the decimal separator; normalise to dot.
          start_s = parse_ts(start_ts.tr(',', '.'))
          end_s   = parse_ts(end_ts.split(/\s+/).first.tr(',', '.'))
          body_idx = lines.index(ts_line) + 1
          body = lines[body_idx..]&.join("\n")
          next unless body && !body.empty?
          cues << Cue.new(start_seconds: start_s, end_seconds: end_s, text: body)
        end
        cues
      end

      def write_srt(cues)
        out = +''
        cues.each_with_index do |c, i|
          out << "#{i + 1}\n"
          out << "#{format_ts(c.start_seconds).tr('.', ',')} --> #{format_ts(c.end_seconds).tr('.', ',')}\n"
          out << "#{c.text}\n\n"
        end
        out
      end

      # ---- WebVTT --------------------------------------------------------

      def parse_vtt(text)
        # Reuses the parser the segmenter already has, with light adaptation
        # so Cue here matches Cue there.
        Segmenter.new(ffmpeg_path: nil, cache_root: nil).parse_cues(text).map do |c|
          Cue.new(start_seconds: c.start_seconds, end_seconds: c.end_seconds, text: c.text)
        end
      end

      def write_vtt(cues)
        out = +"WEBVTT\n\n"
        cues.each do |c|
          out << "#{format_ts(c.start_seconds)} --> #{format_ts(c.end_seconds)}\n#{c.text}\n\n"
        end
        out
      end

      # ---- ASS / SSA ----------------------------------------------------

      ASS_HEADER = <<~ASS.freeze
        [Script Info]
        ScriptType: v4.00+
        Collisions: Normal

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
      ASS

      def parse_ass(text)
        # Lines under [Events] are `Dialogue: layer, h:mm:ss.cc, h:mm:ss.cc, Style, Name, ..., Text`
        cues = []
        in_events = false
        text.each_line do |line|
          line = line.chomp
          if line.start_with?('[')
            in_events = line.include?('Events')
            next
          end
          next unless in_events && line.start_with?('Dialogue:')
          parts = line.sub(/\ADialogue:\s*/, '').split(',', 10)
          next if parts.size < 10
          start_s = parse_ass_ts(parts[1])
          end_s   = parse_ass_ts(parts[2])
          body = parts[9].gsub(/\{[^}]*\}/, '').gsub('\N', "\n")
          cues << Cue.new(start_seconds: start_s, end_seconds: end_s, text: body)
        end
        cues
      end

      def write_ass(cues)
        out = +ASS_HEADER
        cues.each do |c|
          out << "Dialogue: 0,#{format_ass_ts(c.start_seconds)},#{format_ass_ts(c.end_seconds)},Default,,0,0,0,,#{c.text.gsub("\n", '\N')}\n"
        end
        out
      end

      # ---- timestamp helpers ---------------------------------------------

      def parse_ts(ts)
        parts = ts.split(':')
        if parts.size == 3
          parts[0].to_f * 3600 + parts[1].to_f * 60 + parts[2].to_f
        else
          parts[0].to_f * 60 + parts[1].to_f
        end
      end

      # ASS timestamps are H:MM:SS.cc (centiseconds, single-digit hours).
      def parse_ass_ts(ts)
        ts = ts.strip
        h, m, s_cs = ts.split(':')
        h.to_f * 3600 + m.to_f * 60 + s_cs.to_f
      end

      def format_ts(seconds)
        h = (seconds / 3600).to_i
        m = ((seconds % 3600) / 60).to_i
        s = seconds % 60
        format('%02d:%02d:%06.3f', h, m, s)
      end

      def format_ass_ts(seconds)
        h = (seconds / 3600).to_i
        m = ((seconds % 3600) / 60).to_i
        s = seconds % 60
        format('%d:%02d:%05.2f', h, m, s)
      end
    end
  end
end
