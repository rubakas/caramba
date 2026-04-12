class Api::HealthController < Api::BaseController
  BOOT_TIME = Time.current

  def show
    version = ENV.fetch("CARAMBA_VERSION") { read_revision }
    render json: {
      status: "ok",
      version: version,
      booted_at: BOOT_TIME.iso8601
    }
  end

  private

  def read_revision
    # Capistrano puts REVISION in the monorepo root (parent of server/)
    File.read(Rails.root.join("..", "REVISION")).strip
  rescue Errno::ENOENT
    "dev"
  end
end
