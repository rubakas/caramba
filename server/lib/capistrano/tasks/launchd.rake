# lib/capistrano/tasks/launchd.rake
#
# Manages the macOS launchd service for Caramba server.
# Uses launchctl to start/stop/restart the Puma process.

namespace :launchd do
  desc "Install/update the launchd plist on the server"
  task :install do
    on roles(:app) do
      plist_label = fetch(:launchd_label)
      plist_dest  = fetch(:launchd_plist)
      deploy_path = fetch(:deploy_to)
      home_path   = capture(:echo, "$HOME").strip

      # Read template and substitute placeholders
      template = File.read(File.expand_path("../../config/deploy/com.caramba.server.plist.erb", __dir__))
      content  = template
        .gsub("DEPLOY_PATH", deploy_path)
        .gsub("HOME_PATH", home_path)

      # Upload the plist
      upload! StringIO.new(content), plist_dest

      # Unload if already loaded, then load
      execute :launchctl, "unload", plist_dest, raise_on_non_zero_exit: false
      execute :launchctl, "load", plist_dest
      info "launchd service #{plist_label} installed and loaded"
    end
  end

  desc "Start the Caramba server via launchd"
  task :start do
    on roles(:app) do
      execute :launchctl, "start", fetch(:launchd_label)
    end
  end

  desc "Stop the Caramba server via launchd"
  task :stop do
    on roles(:app) do
      execute :launchctl, "stop", fetch(:launchd_label)
    end
  end

  desc "Restart the Caramba server via launchd (stop + start)"
  task :restart do
    on roles(:app) do
      label = fetch(:launchd_label)
      execute :launchctl, "stop", label, raise_on_non_zero_exit: false
      sleep 2
      execute :launchctl, "start", label
      info "Caramba server restarted via launchd"
    end
  end

  desc "Show launchd service status"
  task :status do
    on roles(:app) do
      output = capture(:launchctl, "list", "|", :grep, fetch(:launchd_label), raise_on_non_zero_exit: false)
      if output.strip.empty?
        info "Service #{fetch(:launchd_label)} is not loaded"
      else
        info output
      end
    end
  end
end

# Hook into Capistrano deploy lifecycle
namespace :deploy do
  after :publishing, "launchd:restart"
end
