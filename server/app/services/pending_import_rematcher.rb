# Reverses a confirmed PendingImport: destroys the resulting Show or Movie
# (cascades to episodes/playback_preferences/downloads) and resets the
# import to "pending" with a fresh candidate list, so the admin can pick
# a different match. Called by Api::Admin::PendingImportsController#rematch.

class PendingImportRematcher
  class << self
    def rematch(pending_import)
      ActiveRecord::Base.transaction do
        record = linked_record_for(pending_import)
        record&.destroy!
        pending_import.update!(
          status: "pending",
          chosen_external_id: nil,
          error: nil,
          candidates: LibraryWatcherService.candidates_for(pending_import)
        )
      end
      pending_import
    end

    def linked_record_for(pending_import)
      case pending_import.kind
      when "shows"
        Show.find_by(media_path: pending_import.folder_path)
      when "movies"
        Movie.find_by(file_path: pending_import.folder_path) ||
          Movie.where("file_path LIKE ?", "#{pending_import.folder_path}/%").first
      end
    end
  end
end
