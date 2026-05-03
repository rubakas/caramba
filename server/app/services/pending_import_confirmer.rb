# Turns a PendingImport into a real Show or Movie using the external id
# chosen by an admin. Called by Api::Admin::PendingImportsController#confirm.
#
# Stage order mirrors example.rb's MediaIdentifier and Jellyfin's
# "local providers run first" pattern:
#
#   1. Local — NFO sidecar (tvshow.nfo / movie.nfo) seeds attrs.
#   2. Local — filename-embedded provider IDs ([imdbid-…], etc.).
#   3. Remote — TVmaze / imdbapi.dev. Prefer direct id lookup when
#              an id was discovered locally.
#   4. Background — TechProbeJob caches codec/duration/resolution.

class PendingImportConfirmer
  class << self
    def confirm(pending_import, external_id)
      external_id = external_id.to_s
      raise ArgumentError, "externalId is required" if external_id.blank?

      case pending_import.kind
      when "shows"
        confirm_show(pending_import, external_id)
      when "movies"
        confirm_movie(pending_import, external_id)
      else
        raise "Unknown kind: #{pending_import.kind.inspect}"
      end
    end

    private

    def confirm_show(pending_import, external_id)
      candidate = find_candidate(pending_import, external_id)
      name = candidate&.dig("name").presence || pending_import.parsed_name.presence || File.basename(pending_import.folder_path)

      nfo = NfoParserService.read_show(pending_import.folder_path) || {}
      nfo_imdb = nfo[:imdb_id]
      filename_imdb = FilenameParserService.extract_provider_ids(pending_import.folder_path)[:imdb]
      imdb_id = nfo_imdb || filename_imdb

      show = Show.new(
        name: nfo[:title].presence || name,
        media_path: pending_import.folder_path,
        tvmaze_id: external_id.to_i,
        imdb_id: imdb_id
      )
      show.save!

      MediaScannerService.scan(show)

      # Prefer direct IMDb lookup when known — single exact match, no
      # search fuzziness. Fall back to confirmed tvmaze_id otherwise.
      remote_ok = false
      remote_ok = TvmazeService.fetch_by_imdb_id(show, imdb_id) if imdb_id.present?
      remote_ok ||= TvmazeService.fetch_by_tvmaze_id(show, external_id)

      pending_import.update!(status: "confirmed", chosen_external_id: external_id, error: nil)
      show.reload
    rescue => e
      pending_import.update(status: "failed", error: e.message)
      raise
    end

    def confirm_movie(pending_import, external_id)
      candidate = find_candidate(pending_import, external_id)
      title = candidate&.dig("name").presence || pending_import.parsed_name.presence || File.basename(pending_import.folder_path, File.extname(pending_import.folder_path))
      year = candidate&.dig("year")&.to_s.presence || pending_import.parsed_year&.to_s

      file_path = resolve_movie_file(pending_import.folder_path)

      nfo = NfoParserService.read_movie(file_path) || {}
      filename_imdb = FilenameParserService.extract_provider_ids(file_path)[:imdb]
      imdb_id = nfo[:imdb_id] || filename_imdb || external_id

      movie = Movie.new(
        title: nfo[:title].presence || title,
        file_path: file_path,
        year: nfo[:year].presence || year,
        imdb_id: imdb_id
      )
      movie.save!

      ImdbApiService.fetch_by_imdb_id(movie, imdb_id)
      TechProbeJob.perform_later(movie) if defined?(TechProbeJob)

      pending_import.update!(status: "confirmed", chosen_external_id: external_id, error: nil)
      movie.reload
    rescue => e
      pending_import.update(status: "failed", error: e.message)
      raise
    end

    def find_candidate(pending_import, external_id)
      return nil unless pending_import.candidates.is_a?(Array)
      pending_import.candidates.find { |c| c["externalId"].to_s == external_id }
    end

    def resolve_movie_file(path)
      return path unless File.directory?(path)
      main = LibraryWatcherService.main_video_in(path)
      raise ArgumentError, "No video file found inside #{path}" unless main
      main
    end
  end
end
