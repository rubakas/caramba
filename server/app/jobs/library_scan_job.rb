# Scans every enabled MediaFolder and creates PendingImports for any
# newly-discovered media. Scheduled every 5 minutes via config/recurring.yml
# and also enqueued ad-hoc by POST /api/admin/scan.
#
# Each folder's scan is capped at 20 new imports per run to respect TVMaze's
# rate limit; additional entries are picked up on the next run.

class LibraryScanJob < ApplicationJob
  queue_as :default

  def perform
    MediaFolder.enabled.find_each do |folder|
      LibraryWatcherService.scan_folder(folder)
    end
  end
end
