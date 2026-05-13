require 'open3'

module Jellyfin
  module Subtitle
    # Charset detection for text subtitle files.
    #
    # Strategy in order of preference:
    #   1. BOM check — unambiguous for any UTF encoding
    #   2. `uchardet` CLI — Mozilla's universal detector, what upstream Jellyfin
    #      uses. Available on most distros as a small native binary.
    #   3. Frequency heuristic fallback — covers the common cases when uchardet
    #      isn't installed (cp1251 / cp1252 / shift-jis).
    module Charset
      BOMS = {
        "\xEF\xBB\xBF".b               => 'UTF-8',
        "\xFF\xFE".b                   => 'UTF-16LE',
        "\xFE\xFF".b                   => 'UTF-16BE',
        "\xFF\xFE\x00\x00".b           => 'UTF-32LE',
        "\x00\x00\xFE\xFF".b           => 'UTF-32BE'
      }.freeze

      module_function

      # Returns a string like 'UTF-8' or 'WINDOWS-1252', or nil if undetectable.
      def detect(path_or_bytes)
        bytes = read_or_passthrough(path_or_bytes)
        return 'UTF-8' if bytes.empty?

        # 1. BOM check first — unambiguous.
        BOMS.each do |bom, name|
          return name if bytes.start_with?(bom)
        end

        # 2. uchardet shell-out when input is a file path. Avoid piping bytes
        # through stdin because the CLI bails on NULs and large inputs.
        if path_or_bytes.is_a?(String) && !path_or_bytes.include?("\0") && File.exist?(path_or_bytes)
          name = detect_with_uchardet(path_or_bytes)
          return name if name && !name.casecmp('unknown').zero?
        end

        # 3. Valid UTF-8?
        utf8_attempt = bytes.dup.force_encoding('UTF-8')
        return 'UTF-8' if utf8_attempt.valid_encoding?

        # 4. Frequency heuristic for common 8-bit encodings.
        guess_8bit(bytes)
      end

      # Public so tests can stub it; returns nil when uchardet is unavailable
      # or fails.
      def detect_with_uchardet(path)
        return nil if @uchardet_unavailable
        out, _err, status = Open3.capture3('uchardet', path)
        return nil unless status.success?
        result = out.strip
        result.empty? ? nil : result.upcase
      rescue Errno::ENOENT
        # No `uchardet` binary on PATH — skip it for the remainder of the
        # process so we don't pay the spawn cost on every subtitle.
        @uchardet_unavailable = true
        nil
      rescue StandardError
        nil
      end

      # Test helper — resets the "unavailable" memoization between specs.
      def reset_uchardet_cache!
        @uchardet_unavailable = nil
      end

      # ffmpeg `subtitles=` filter expects ICU codepage names. Translate.
      def to_iconv(name)
        case name&.upcase
        when 'UTF-8', nil then nil # default; no override needed
        when 'WINDOWS-1252'      then 'cp1252'
        when 'WINDOWS-1251'      then 'cp1251'
        when 'SHIFT_JIS', 'SHIFT-JIS' then 'shift_jis'
        when 'GB18030'           then 'gb18030'
        when 'BIG5'              then 'big5'
        when 'EUC-KR'            then 'euc-kr'
        when 'ISO-8859-1'        then 'latin1'
        else name.downcase
        end
      end

      def guess_8bit(bytes)
        # Cyrillic in cp1251 packs the 0xC0..0xFF range densely; accented Latin
        # in cp1252 spreads across both 0x80..0xBF and 0xC0..0xFF. So the
        # disambiguator is: is the 0xC0..0xFF range dominant *and* sustained?
        # If only a few high bytes show up, it's probably cp1252.
        upper   = bytes.each_byte.count { |b| (0xC0..0xFF).cover?(b) }
        upper8x = bytes.each_byte.count { |b| (0x80..0xFF).cover?(b) }
        shift_jis_lead = bytes.each_byte.count { |b| (0x81..0x9F).cover?(b) || (0xE0..0xEF).cover?(b) }
        total = bytes.bytesize.to_f
        return nil if total.zero?

        return 'SHIFT_JIS'    if shift_jis_lead / total > 0.10 && upper.zero?
        # cp1251 only fires when nearly every non-ASCII byte is in the cyrillic
        # range AND that range is densely populated.
        return 'WINDOWS-1251' if upper / total > 0.30 && upper == upper8x
        return 'WINDOWS-1252' if upper8x.positive?
        nil
      end

      def read_or_passthrough(input)
        # `input` might be a path or raw bytes. We only treat it as a path when
        # it's NUL-free (paths can't contain NUL) AND the file actually exists.
        if input.is_a?(String) && !input.include?("\0") && File.exist?(input)
          File.binread(input, 4096)
        else
          input.to_s.b
        end
      rescue StandardError
        input.to_s.b
      end
    end
  end
end
