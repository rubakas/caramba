class Api::BaseController < ActionController::API
  include ActiveStorage::SetCurrent
  include Rails.application.routes.url_helpers

  STUBBED_TEST_ACTIONS = Set[
    "Api::PlaybackController#report_progress",
    "Api::EpisodesController#toggle",
    "Api::MoviesController#toggle",
  ].freeze

  before_action :short_circuit_test_writes

  rescue_from ActiveRecord::RecordNotFound, with: :not_found
  rescue_from ActiveRecord::RecordInvalid, with: :unprocessable

  private

  def test_run?
    request.headers["X-Test-Run"] == "1"
  end

  def short_circuit_test_writes
    return unless test_run?
    key = "#{self.class.name}##{action_name}"

    if key == "Api::MoviesController#play"
      movie = Movie.find_by!(slug: params[:slug])
      return render(json: { error: "File not found: #{movie.file_path}" }, status: :unprocessable_entity) unless movie.file_path.present? && File.exist?(movie.file_path)
      return render json: { movie_id: movie.id, file_path: movie.file_path, start_time: movie.resume_time }
    end

    if key == "Api::EpisodesController#play"
      ep = Episode.find(params[:id])
      return render(json: { error: "File not found: #{ep.file_path}" }, status: :unprocessable_entity) unless ep.file_path.present? && File.exist?(ep.file_path)
      # Read-only: do NOT create a WatchHistory row; client tolerates a nil watch_history_id.
      return render json: { episode_id: ep.id, show_id: ep.show_id, watch_history_id: ep.watch_histories.last&.id, file_path: ep.file_path, start_time: ep.resume_time }
    end

    return unless STUBBED_TEST_ACTIONS.include?(key)
    render json: { ok: true, testMode: true }
  end

  def not_found
    render json: { error: "Not found" }, status: :not_found
  end

  def unprocessable(exception)
    render json: { error: exception.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
  end

  # Returns the URL for an attached poster if present, otherwise falls back to
  # the external URL stored on the record. The blob itself is already resized
  # at download time (see Posterable#download_poster!), so we can serve it
  # directly without a variant hop.
  def poster_url_for(record)
    if record.respond_to?(:poster) && record.poster.attached?
      "#{request.base_url}#{rails_storage_proxy_path(record.poster)}"
    else
      record.try(:poster_url)
    end
  end
end
