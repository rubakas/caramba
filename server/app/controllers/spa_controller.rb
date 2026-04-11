# Serves the React SPA index.html for all non-API routes.
# This enables client-side routing (BrowserRouter) in production.
class SpaController < ActionController::Base
  def index
    file = Rails.public_path.join("index.html")
    if file.exist?
      render file: file, layout: false, content_type: "text/html"
    else
      render plain: "Not found — run the frontend build first.", status: :not_found
    end
  end
end
