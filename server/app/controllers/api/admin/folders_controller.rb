class Api::Admin::FoldersController < Api::Admin::BaseController
  before_action :set_folder, only: [ :update, :destroy ]

  def index
    render json: MediaFolder.order(:path).map { |f| serialize(f) }
  end

  def create
    folder = MediaFolder.new(create_params)
    if folder.save
      render json: serialize(folder), status: :created
    else
      render json: { error: folder.errors.full_messages.join(", ") }, status: :unprocessable_entity
    end
  end

  def update
    if @folder.update(update_params)
      render json: serialize(@folder)
    else
      render json: { error: @folder.errors.full_messages.join(", ") }, status: :unprocessable_entity
    end
  end

  def destroy
    @folder.destroy
    head :no_content
  end

  private

  def set_folder
    @folder = MediaFolder.find(params[:id])
  end

  def create_params
    params.permit(:path, :kind)
  end

  def update_params
    params.permit(:enabled)
  end

  def serialize(folder)
    {
      id: folder.id,
      path: folder.path,
      kind: folder.kind,
      enabled: folder.enabled,
      lastScannedAt: folder.last_scanned_at
    }
  end
end
