module Jellyfin
  module Encoding
    # Port of EncodingHelper.GetGraphicalSubCanvasSize (cs:969). Returns the
    # `-canvas_size WxH` arg pair when the subtitle stream is a graphical
    # (PGS / DVD / DVB) bitmap that must be rendered against the source
    # canvas before overlay.
    #
    # Upstream excludes DVBSUB explicitly because its canvas is fixed at
    # 720x576 and ffmpeg already knows the size.
    module GraphicalSubCanvas
      EXCLUDED_CODECS = %w[dvbsub].freeze

      module_function

      # Returns an args array `['-canvas_size', 'WxH']` or [].
      def args(job)
        return [] unless job.burn_subtitles?
        stream = job.subtitle_stream
        return [] if stream.nil?
        return [] if stream.codec.to_s.downcase.match?(/text|subrip|webvtt|ass|ssa/)
        return [] if EXCLUDED_CODECS.include?(stream.codec.to_s.downcase)

        w = stream.width.to_i
        h = stream.height.to_i
        return [] if w.zero? || h.zero?
        ['-canvas_size', "#{w}x#{h}"]
      end
    end
  end
end
