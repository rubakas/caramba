class Api::HealthController < Api::BaseController
  def show
    render json: { status: "ok" }
  end
end
