require "socket"

class Api::HealthController < Api::BaseController
  BOOT_TIME = Time.current

  def show
    render json: {
      status: "ok",
      version: ENV.fetch("CARAMBA_VERSION") { read_revision },
      booted_at: BOOT_TIME.iso8601,
      server_name: Socket.gethostname.sub(/\.local\.?\z/, "")
    }
  end

  private

  def read_revision
    # Capistrano puts REVISION in the monorepo root (parent of server/).
    File.read(Rails.root.join("..", "REVISION")).strip
  rescue Errno::ENOENT
    "dev"
  end
end
