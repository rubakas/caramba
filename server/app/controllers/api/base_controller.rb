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
  # the external URL stored on the record. Served via ActiveStorage's proxy
  # controller as a resized variant — some IMDb originals are 8K × 12K / 10 MB,
  # which slaughters initial-load time on TV even with caching.
  def poster_url_for(record)
    variant = record.try(:poster_variant)
    if variant
      "#{request.base_url}#{rails_blob_representation_proxy_path(
        signed_blob_id: variant.blob.signed_id,
        variation_key: variant.variation.key,
        filename: variant.blob.filename
      )}"
    else
      record.try(:poster_url)
    end
  end
end
