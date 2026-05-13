# Runs ffprobe against an Episode/Movie file and caches the result on
# the row. Idempotent — re-runs are cheap if the row already has data
# and the file size hasn't changed.
#
# Enqueued by MediaScannerService and PendingImportConfirmer after each
# new media row is saved.

class TechProbeJob < ApplicationJob
  queue_as :default

  discard_on ActiveJob::DeserializationError

  def perform(record)
    TechProbeService.probe_for(record)
  end
end
