module Jellyfin
  module Probing
    # Port of upstream's `Video3DFormat` enum + detection. ProbeResultNormalizer
    # picks 3D format from ffprobe's `Stereo 3D` side data + filename
    # patterns; we mirror the same two-stage detection.
    #
    # Recognised formats (subset of upstream):
    #   :sbs   — side-by-side (full or half)
    #   :ou    — over-under (top/bottom)
    #   :hsbs  — half-width side-by-side (most consumer 3D Blu-rays)
    #   :hou   — half-height over-under
    #   :mvc   — Multi-view coding (Blu-ray 3D, two streams)
    #
    # Detection order: side_data wins; filename fallback otherwise.
    module Stereo3d
      MODE_TAGS = {
        'side_by_side'   => :sbs,
        'side_by_side_l' => :sbs,
        'side_by_side_r' => :sbs,
        'side by side (left first)' => :sbs,
        'top_bottom'     => :ou,
        'top-bottom'     => :ou,
        'l_b_or_t_b'     => :ou
      }.freeze

      FILENAME_PATTERNS = {
        :sbs   => /\b(sbs|side[ ._-]?by[ ._-]?side)\b/i,
        :hsbs  => /\bhalf[ ._-]?sbs|hsbs\b/i,
        :ou    => /\bou\b|over[ ._-]?under|top[ ._-]?bottom/i,
        :hou   => /\bhalf[ ._-]?ou|hou\b/i,
        :mvc   => /\b(3d[ ._-]?bluray|mvc)\b/i
      }.freeze

      module_function

      # Inspect the side_data block from ffprobe for stereo3d metadata.
      def detect_from_side_data(side_data_list)
        return nil unless side_data_list.is_a?(Array)
        rec = side_data_list.find { |d| d.is_a?(Hash) && d['side_data_type'].to_s.casecmp('Stereo 3D').zero? }
        return nil unless rec
        type = rec['type'].to_s.downcase
        MODE_TAGS[type]
      end

      # Inspect the source filename / container tags.
      def detect_from_filename(path)
        return nil unless path
        # Half-* patterns are more specific than the plain ones — check first.
        return :hsbs if FILENAME_PATTERNS[:hsbs].match?(path)
        return :hou  if FILENAME_PATTERNS[:hou].match?(path)
        FILENAME_PATTERNS.except(:hsbs, :hou).each do |fmt, pattern|
          return fmt if pattern.match?(path)
        end
        nil
      end

      # Combined detector used by ProbeResultNormalizer. Side-data wins;
      # filename is the fallback.
      def detect(side_data_list, path)
        detect_from_side_data(side_data_list) || detect_from_filename(path)
      end
    end
  end
end
