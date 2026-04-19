# Walks each enabled MediaFolder, discovers top-level entries that are not
# yet tracked (no matching Series/Movie record, no existing PendingImport),
# and enqueues them as PendingImports with candidate matches from
# TvmazeService (series) or ImdbApiService (movies).
#
# Called from LibraryScanJob. Caps itself at NEW_IMPORTS_PER_RUN per
# invocation to respect TVMaze's 20/10s rate limit and to keep a single
# run bounded on large libraries — additional entries are picked up on
# subsequent runs (scheduled every 5 minutes).

class LibraryWatcherService
  NEW_IMPORTS_PER_RUN = 20
  THROTTLE_SECONDS = Rails.env.test? ? 0 : 0.2
  MOVIE_FILE_RE = /\.(?:mkv|mp4|avi|mov|m4v)\z/i

  class << self
    def scan_folder(media_folder)
      return 0 unless Dir.exist?(media_folder.path)

      created = 0
      candidates_for_scan(media_folder).each do |entry_path|
        break if created >= NEW_IMPORTS_PER_RUN
        next if already_known?(media_folder.kind, entry_path)

        pending = build_pending_import(media_folder, entry_path)
        next unless pending

        if pending.save
          created += 1
          sleep(THROTTLE_SECONDS)
        else
          Rails.logger.warn("LibraryWatcher: failed to save PendingImport for #{entry_path} — #{pending.errors.full_messages.join(', ')}")
        end
      end

      media_folder.update(last_scanned_at: Time.current)
      created
    end

    # Re-query the external API for a given pending import and return the
    # fresh candidate list. Used by the "Re-search" button.
    def candidates_for(pending_import)
      case pending_import.kind
      when "series"
        tvmaze_candidates(pending_import.parsed_name.to_s)
      when "movies"
        query = pending_import.parsed_year.present? ? "#{pending_import.parsed_name} #{pending_import.parsed_year}" : pending_import.parsed_name.to_s
        imdb_candidates(query)
      else
        []
      end
    end

    private

    def candidates_for_scan(media_folder)
      root = media_folder.path
      Dir.children(root).sort.filter_map do |name|
        next if name.start_with?(".")
        full = File.join(root, name)
        case media_folder.kind
        when "series"
          full if File.directory?(full)
        when "movies"
          full if File.directory?(full) || (File.file?(full) && full.match?(MOVIE_FILE_RE))
        end
      end
    end

    def already_known?(kind, entry_path)
      case kind
      when "series"
        return true if Series.exists?(media_path: entry_path)
      when "movies"
        return true if Movie.exists?(file_path: entry_path)
      end
      PendingImport.exists?(folder_path: entry_path)
    end

    def build_pending_import(media_folder, entry_path)
      case media_folder.kind
      when "series"
        build_series_import(media_folder, entry_path)
      when "movies"
        build_movie_import(media_folder, entry_path)
      end
    end

    def build_series_import(media_folder, entry_path)
      name = MediaScannerService.name_from_path(entry_path)
      return nil if name.blank?

      candidates = tvmaze_candidates(name)
      PendingImport.new(
        media_folder: media_folder,
        folder_path: entry_path,
        kind: "series",
        parsed_name: name,
        candidates: candidates
      )
    end

    def build_movie_import(media_folder, entry_path)
      name = MovieParserService.name_from_filename(entry_path)
      return nil if name.blank?

      year = MovieParserService.year_from_filename(entry_path)
      query = year.present? ? "#{name} #{year}" : name
      candidates = imdb_candidates(query)

      PendingImport.new(
        media_folder: media_folder,
        folder_path: entry_path,
        kind: "movies",
        parsed_name: name,
        parsed_year: year&.to_i,
        candidates: candidates
      )
    end

    def tvmaze_candidates(query)
      results = TvmazeService.search_shows(query) || []
      results.first(5).map do |s|
        {
          "externalId" => s["tvmaze_id"],
          "name" => s["name"],
          "posterUrl" => s["poster_url"],
          "year" => s["premiered"].to_s[0, 4].presence,
          "rating" => s["rating"],
          "description" => s["description"],
          "source" => "tvmaze"
        }
      end
    end

    def imdb_candidates(query)
      results = ImdbApiService.search_titles(query) || []
      results.first(5).map do |m|
        {
          "externalId" => m["imdb_id"],
          "name" => m["name"],
          "posterUrl" => m["poster_url"],
          "year" => m["year"],
          "rating" => m["rating"],
          "description" => nil,
          "source" => "imdb"
        }
      end
    end
  end
end
