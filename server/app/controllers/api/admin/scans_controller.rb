class Api::Admin::ScansController < Api::Admin::BaseController
  # Triggers LibraryScanJob immediately. The recurring scheduler also runs
  # every 5 minutes (see config/recurring.yml), so this is for the "Scan now"
  # button in the admin UI.
  def create
    LibraryScanJob.perform_later
    render json: { enqueued: true }, status: :accepted
  end
end
