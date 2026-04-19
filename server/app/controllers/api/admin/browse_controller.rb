class Api::Admin::BrowseController < Api::Admin::BaseController
  def index
    path = params[:path].to_s

    if path.blank?
      render json: { path: nil, parent: nil, entries: [], mounts: FilesystemBrowserService.list_mounts }
      return
    end

    listing = FilesystemBrowserService.list_entries(path)
    render json: {
      path: listing["path"],
      parent: listing["parent"],
      entries: listing["entries"],
      mounts: []
    }
  rescue FilesystemBrowserService::InvalidPath => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
end
