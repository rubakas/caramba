class Api::BaseController < ActionController::API
  include ActiveStorage::SetCurrent
  include Rails.application.routes.url_helpers

  rescue_from ActiveRecord::RecordNotFound, with: :not_found
  rescue_from ActiveRecord::RecordInvalid, with: :unprocessable

  private

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
