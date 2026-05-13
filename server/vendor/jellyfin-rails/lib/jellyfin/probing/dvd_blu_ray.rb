module Jellyfin
  module Probing
    # Ports the multi-file DVD VOB / Blu-ray M2TS grouping logic from
    # MediaEncoder.GetPrimaryPlaylistVobFiles (cs:1222) and the Blu-ray
    # equivalent at the bottom of the same class.
    #
    # DVDs ship as a tree of VTS_NN_M.VOB files under VIDEO_TS/. Blu-rays
    # use NNNN.M2TS under BDMV/STREAM/. Both have a "primary title" notion:
    # the longest-running concatenation of files that represents the main
    # feature. Upstream picks it heuristically (largest title by file size).
    module DvdBluRay
      VTS_FILE_RE = /\AVTS_(\d{2})_(\d).VOB\z/i.freeze
      M2TS_FILE_RE = /\A(\d{5}).m2ts\z/i.freeze

      Title = Struct.new(:number, :files, :total_size, keyword_init: true) do
        def main? = total_size > 900 * 1024 * 1024 # >900 MB ≈ feature length
      end

      module_function

      # Port of GetPrimaryPlaylistVobFiles (cs:1222). Returns the .VOB paths
      # in concat order for `title_number`. When title is unspecified, picks
      # the largest title (typical "Play Movie" entry).
      def primary_vob_files(dvd_root, title_number: nil)
        return [] unless File.directory?(dvd_root)
        all_vobs = Dir.glob(File.join(dvd_root, '**', '*.VOB'), File::FNM_CASEFOLD)
        # Mirrors cs:1224 — strip VIDEO_TS.VOB (menu) + _0.VOB (intro per title).
        all_vobs = all_vobs.reject { |p| File.basename(p).casecmp('VIDEO_TS.VOB').zero? }
        all_vobs = all_vobs.reject { |p| File.basename(p).match?(/_0\.VOB\z/i) }
        all_vobs.sort!

        titles = group_vobs_by_title(all_vobs)
        return [] if titles.empty?

        chosen = title_number ? titles.find { |t| t.number == title_number.to_i } : pick_main_title(titles)
        chosen ? chosen.files : []
      end

      def group_vobs_by_title(vobs)
        groups = vobs.group_by { |p| (File.basename(p)[VTS_FILE_RE, 1] || '00').to_i }
        groups.map do |number, files|
          Title.new(
            number: number,
            files: files.sort,
            total_size: files.sum { |f| File.size(f) rescue 0 }
          )
        end
      end

      # Mirrors the upstream tiebreaker logic at cs:1245-1278:
      # filter to titles >900 MB, pick the one with the largest total size.
      def pick_main_title(titles)
        big = titles.select(&:main?)
        big = titles if big.empty?
        big.max_by(&:total_size)
      end

      # Blu-ray equivalent. M2TS files live under BDMV/STREAM/.
      def primary_m2ts_files(bd_root, title_number: nil)
        stream_dir = File.join(bd_root, 'BDMV', 'STREAM')
        return [] unless File.directory?(stream_dir)
        all_m2ts = Dir.glob(File.join(stream_dir, '*.m2ts'), File::FNM_CASEFOLD).sort

        if title_number
          numbered = format('%05d', title_number.to_i)
          matched = all_m2ts.find { |p| File.basename(p, '.m2ts') == numbered }
          return [matched].compact
        end

        # No clip-info parsing → pick the largest file as the main feature.
        largest = all_m2ts.max_by { |p| File.size(p) rescue 0 }
        largest ? [largest] : []
      end
    end
  end
end
