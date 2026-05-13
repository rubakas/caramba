require 'open3'
require 'fileutils'

module Jellyfin
  module Images
    # Port of MediaEncoder.ConvertImage (cs:1216). Upstream throws
    # `NotImplementedException`; we provide a working implementation via
    # ffmpeg since the same binary already on hand handles every common
    # raster format.
    #
    # Used by /Items/{id}/Images endpoints when the client requests an
    # image format the server has cached in a different one (e.g., cached
    # JPEG poster + client asks for WebP).
    class Converter
      class ConversionFailed < StandardError; end

      SUPPORTED_FORMATS = %w[.jpg .jpeg .png .webp .bmp .gif .tiff].freeze

      def initialize(ffmpeg_path: nil)
        @ffmpeg = ffmpeg_path || Jellyfin::Rails.configuration.ffmpeg_path
      end

      # Reads from `input_path`, writes to `output_path`. The output extension
      # determines the target format. Optional `quality` (1-100) for lossy
      # outputs.
      def convert(input_path:, output_path:, quality: nil)
        raise ConversionFailed, 'input not found' unless File.exist?(input_path)
        raise ConversionFailed, 'unsupported input format' unless SUPPORTED_FORMATS.include?(File.extname(input_path).downcase)
        raise ConversionFailed, 'unsupported output format' unless SUPPORTED_FORMATS.include?(File.extname(output_path).downcase)

        FileUtils.mkdir_p(File.dirname(output_path))

        args = [@ffmpeg, '-y', '-hide_banner', '-loglevel', 'error', '-i', input_path]
        # JPEG / WebP quality flag. ffmpeg's `-q:v 2` is visually-lossless
        # JPEG, 31 is worst. We map 1-100 to 31-1 (inverted scale).
        if quality && %w[.jpg .jpeg .webp].include?(File.extname(output_path).downcase)
          q = (31 - (quality.to_f / 100 * 30).round).clamp(1, 31)
          args.concat(['-q:v', q.to_s])
        end
        args << output_path

        _stdout, stderr, status = Open3.capture3(*args)
        raise ConversionFailed, stderr.strip unless status.success? && File.exist?(output_path)
        output_path
      end
    end
  end
end
