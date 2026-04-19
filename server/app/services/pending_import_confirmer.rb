# Turns a PendingImport into a real Show or Movie using the external id
# chosen by an admin. Called by Api::Admin::PendingImportsController#confirm.
#
# The external id comes from one of the PendingImport#candidates entries.
# The name/year displayed on the picked candidate is used to seed the
# Show/Movie record before the TVMaze/IMDb fetch enriches it — this keeps
# the user's choice authoritative even if the API lookup later returns
# slightly different data.

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

      show = Show.new(
        name: name,
        media_path: pending_import.folder_path,
        tvmaze_id: external_id.to_i
      )
      show.save!

      MediaScannerService.scan(show)
      TvmazeService.fetch_by_tvmaze_id(show, external_id)

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

      movie = Movie.new(
        title: title,
        file_path: pending_import.folder_path,
        year: year,
        imdb_id: external_id
      )
      movie.save!

      ImdbApiService.fetch_by_imdb_id(movie, external_id)

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
  end
end
