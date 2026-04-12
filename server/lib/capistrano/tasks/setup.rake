# lib/capistrano/tasks/setup.rake
#
# One-time setup tasks for the NAS server.

namespace :caramba do
  desc "First-time NAS setup: create directories, install plist, copy master.key"
  task :setup do
    on roles(:app) do
      deploy_path = fetch(:deploy_to)

      # Create shared directories
      execute :mkdir, "-p",
        "#{deploy_path}/shared/server/storage",
        "#{deploy_path}/shared/server/log",
        "#{deploy_path}/shared/server/tmp/pids",
        "#{deploy_path}/shared/server/tmp/cache",
        "#{deploy_path}/shared/server/tmp/sockets",
        "#{deploy_path}/shared/server/vendor/bundle",
        "#{deploy_path}/shared/server/config",
        "#{deploy_path}/shared/node_modules",
        "#{deploy_path}/shared/web/node_modules"

      info "Shared directories created at #{deploy_path}/shared/"
      warn "Don't forget to copy master.key:"
      warn "  scp server/config/master.key nas.local:#{deploy_path}/shared/server/config/master.key"
    end
  end

  desc "Copy master.key to the server"
  task :upload_master_key do
    on roles(:app) do
      key_path = "#{fetch(:deploy_to)}/shared/server/config/master.key"
      local_key = File.expand_path("config/master.key", __dir__.gsub("/lib/capistrano/tasks", ""))
      if File.exist?(local_key)
        upload! local_key, key_path
        execute :chmod, "600", key_path
        info "master.key uploaded to #{key_path}"
      else
        error "Local config/master.key not found!"
      end
    end
  end

  desc "View server logs"
  task :logs do
    on roles(:app) do
      execute :tail, "-f", "#{fetch(:deploy_to)}/shared/server/log/launchd.stderr.log", raise_on_non_zero_exit: false
    end
  end

  desc "Open Rails console on the server"
  task :console do
    on roles(:app) do |server|
      exec "ssh #{server.user}@#{server.hostname} -t 'cd #{fetch(:deploy_to)}/current/server && RAILS_ENV=production ~/.local/share/mise/shims/bundle exec rails console'"
    end
  end
end
