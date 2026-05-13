require 'open3'

module Jellyfin
  module MediaEncoder
    # Probes a local ffmpeg binary for supported encoders, decoders, filters, and
    # hardware accelerators. Mirrors MediaBrowser.MediaEncoding/Encoder/EncoderValidator.cs
    # at the level of detail jellyfin-rails actually consumes.
    class EncoderValidator
      Capabilities = Struct.new(:version, :encoders, :decoders, :filters, :hwaccels, keyword_init: true) do
        def supports_encoder?(name)
          encoders.include?(name)
        end

        def supports_decoder?(name)
          decoders.include?(name)
        end

        def supports_filter?(name)
          filters.include?(name)
        end

        def supports_hwaccel?(name)
          hwaccels.include?(name)
        end

        def to_h_summary
          {
            version: version,
            encoders: encoders.sort,
            decoders: decoders.sort,
            filters: filters.sort,
            hwaccels: hwaccels.sort
          }
        end
      end

      def initialize(ffmpeg_path)
        @ffmpeg_path = ffmpeg_path
      end

      def probe
        Capabilities.new(
          version: read_version,
          encoders: read_list('-encoders', /^\s+[A-Z\.]+\s+(\S+)/),
          decoders: read_list('-decoders', /^\s+[A-Z\.]+\s+(\S+)/),
          filters:  read_list('-filters',  /^\s+[A-Z\.]+\s+(\S+)/),
          hwaccels: read_hwaccels
        )
      end

      private

      def read_version
        out, _err, status = Open3.capture3(@ffmpeg_path, '-version')
        return nil unless status.success?
        out.lines.first&.match(/ffmpeg version (\S+)/)&.captures&.first
      end

      def read_list(flag, line_re)
        out, _err, status = Open3.capture3(@ffmpeg_path, '-hide_banner', flag)
        return [] unless status.success?
        out.lines.filter_map { |l| l.match(line_re)&.captures&.first }.uniq
      end

      def read_hwaccels
        out, _err, status = Open3.capture3(@ffmpeg_path, '-hide_banner', '-hwaccels')
        return [] unless status.success?
        out.lines.map(&:strip).reject { |l| l.empty? || l.start_with?('Hardware') }
      end
    end
  end
end
