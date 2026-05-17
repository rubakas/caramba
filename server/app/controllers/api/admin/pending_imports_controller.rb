class Api::Admin::PendingImportsController < Api::Admin::BaseController
  before_action :set_pending_import, only: [ :confirm, :ignore, :research, :switch_kind, :rematch ]

  def index
    scope = PendingImport.all
    scope = scope.where(status: params[:status]) if params[:status].present?
    order = params[:status] == "confirmed" ? { updated_at: :desc } : { created_at: :desc }
    scope = scope.order(order)
    scope = scope.limit(params[:limit].to_i) if params[:limit].present? && params[:limit].to_i.positive?
    render json: scope.map { |pi| serialize(pi) }
  end

  def confirm
    external_id = (params[:externalId] || params[:external_id]).to_s
    record = PendingImportConfirmer.confirm(@pending_import, external_id)

    case @pending_import.kind
    when "shows"
      render json: { show: record.as_json.merge("poster_url" => poster_url_for(record)) }, status: :created
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
    candidates = LibraryWatcherService.candidates_for(@pending_import, query: params[:query])
    @pending_import.update!(candidates: candidates, status: "pending", error: nil)
    render json: serialize(@pending_import)
  end

  # Undo a confirmed match: destroy the resulting Show/Movie (cascades to
  # episodes/playback_preferences/downloads) and re-open the import for
  # matching with a fresh candidate list. Used when the admin picked the
  # wrong candidate.
  def rematch
    PendingImportRematcher.rematch(@pending_import)
    render json: serialize(@pending_import.reload)
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # Flip a misclassified import between "shows" and "movies" and re-fetch
  # candidates from the right service. Used when the same root is
  # registered as both kinds and the show scan claimed a movie folder
  # (or vice-versa).
  def switch_kind
    new_kind = (params[:kind] || params[:newKind]).to_s
    if LibraryWatcherService.switch_kind(@pending_import, new_kind)
      render json: serialize(@pending_import.reload)
    else
      render json: { error: "Cannot switch to '#{new_kind}'" }, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
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
