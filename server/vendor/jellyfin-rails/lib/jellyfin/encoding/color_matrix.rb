module Jellyfin
  module Encoding
    # Colour-matrix conversion. When the output resolution crosses a band that
    # implies a different colourspace (SD = BT.601, HD = BT.709, UHD/HDR =
    # BT.2020), we need to convert the matrix or the output will look subtly
    # wrong on standards-compliant displays.
    #
    # Typical case: downscaling a 4K BT.2020 source to 1080p for a phone that
    # expects BT.709. Without conversion the colours come out muted.
    #
    # Mirrors EncodingHelper.cs `GetOutputSizeParam`'s embedded colour-matrix
    # decision (search for `colormatrix=`).
    module ColorMatrix
      module_function

      # Returns a `colormatrix=src:dst` filter fragment, or nil if the source
      # and target matrices match.
      def build(job)
        src = source_matrix(job.video_stream)
        dst = target_matrix(job)
        return nil if src.nil? || dst.nil? || src == dst
        "colormatrix=#{src}:#{dst}"
      end

      def source_matrix(stream)
        return nil unless stream
        cs = stream.color_space.to_s.downcase
        return 'bt2020nc' if cs.include?('bt2020')
        return 'bt709'    if cs == 'bt709'
        return 'bt601'    if cs.match?(/bt470|smpte170|601/)
        nil
      end

      def target_matrix(job)
        h = job.output_height || job.video_stream&.height || 0
        # Standard mapping: UHD = bt2020, HD = bt709, SD = bt601.
        return 'bt2020nc' if h >= 1440
        return 'bt709'    if h >= 720
        'bt601'
      end
    end
  end
end
