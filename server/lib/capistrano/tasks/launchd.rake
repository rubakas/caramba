# lib/capistrano/tasks/launchd.rake
#
# Manages the macOS launchd service for Caramba server.
# Uses launchctl to start/stop/restart the Puma process.

namespace :launchd do
  desc "Install/update the launchd plist on the server"
  task :install do
    on roles(:app) do
      label = fetch(:launchd_label)
      deploy_path = fetch(:deploy_to)
      home_path = capture(:echo, "$HOME").strip
      plist_dest = "#{home_path}/Library/LaunchAgents/#{label}.plist"

      # Read template and substitute placeholders
      template = File.read(File.expand_path("../../config/deploy/com.caramba.server.plist.erb", __dir__))
      content = template
        .gsub("DEPLOY_PATH", deploy_path)
        .gsub("HOME_PATH", home_path)

      # Ensure directory exists
      execute :mkdir, "-p", "#{home_path}/Library/LaunchAgents"

      # Upload the plist
      upload! StringIO.new(content), plist_dest

      # Unload if already loaded, then load
      execute :launchctl, "unload", plist_dest, raise_on_non_zero_exit: false
      execute :launchctl, "load", plist_dest
      info "launchd service #{label} installed and loaded"
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

  desc "Restart the Caramba server via launchd (unload + load)"
  task :restart do
    on roles(:app) do
      label = fetch(:launchd_label)
      home = capture(:echo, "$HOME").strip
      plist = "#{home}/Library/LaunchAgents/#{label}.plist"
      execute :launchctl, "unload", plist, raise_on_non_zero_exit: false
      execute :launchctl, "load", plist
      info "Caramba server restarted"
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
