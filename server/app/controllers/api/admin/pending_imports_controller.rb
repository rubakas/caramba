class Api::Admin::PendingImportsController < Api::Admin::BaseController
  before_action :set_pending_import, only: [ :confirm, :ignore, :research ]

  def index
    scope = PendingImport.all
    scope = scope.where(status: params[:status]) if params[:status].present?
    render json: scope.order(created_at: :desc).map { |pi| serialize(pi) }
  end

  def confirm
    external_id = (params[:externalId] || params[:external_id]).to_s
    record = PendingImportConfirmer.confirm(@pending_import, external_id)

    case @pending_import.kind
    when "series"
      render json: { series: record.as_json.merge("poster_url" => poster_url_for(record)) }, status: :created
    when "movies"
      render json: { movie: record.as_json.merge("poster_url" => poster_url_for(record)) }, status: :created
    end
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue => e
    Rails.logger.warn("confirm PendingImport ##{@pending_import.id} failed: #{e.message}")
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def ignore
    @pending_import.update!(status: "ignored")
    head :no_content
  end

  def research
    candidates = LibraryWatcherService.candidates_for(@pending_import)
    @pending_import.update!(candidates: candidates, status: "pending", error: nil)
    render json: serialize(@pending_import)
  end

  private

  def set_pending_import
    @pending_import = PendingImport.find(params[:id])
  end

  def serialize(pi)
    {
      id: pi.id,
      mediaFolderId: pi.media_folder_id,
      folderPath: pi.folder_path,
      kind: pi.kind,
      parsedName: pi.parsed_name,
      parsedYear: pi.parsed_year,
      candidates: pi.candidates || [],
      status: pi.status,
      chosenExternalId: pi.chosen_external_id,
      error: pi.error,
      createdAt: pi.created_at,
      updatedAt: pi.updated_at
    }
  end
end
