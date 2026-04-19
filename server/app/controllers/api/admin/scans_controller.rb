class Api::Admin::ScansController < Api::Admin::BaseController
  # Runs the library scan synchronously so the admin UI gets immediate
  # feedback. The recurring scheduler (config/recurring.yml) runs the same
  # job every 5 minutes via SolidQueue's `bin/jobs` process — that's the
  # auto-pickup path. This endpoint is the explicit "Scan now" path.
  def create
    created = MediaFolder.enabled.sum { |f| LibraryWatcherService.scan_folder(f) }
    pending = PendingImport.pending.count
    render json: { ok: true, created: created, pending: pending }
  end
end

