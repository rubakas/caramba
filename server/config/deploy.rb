# config/deploy.rb — Capistrano deploy configuration for Caramba server
#
# Deploys the full monorepo, then runs bundle install in server/ and
# builds the React web app into server/public/ for production serving.

lock "~> 3.20"

set :application, "caramba"
set :repo_url, "git@github.com:rubakas/caramba.git"
set :branch, `git rev-parse --abbrev-ref HEAD`.chomp

# Deploy the full monorepo (no repo_tree) because we need ui/ + web/ for
# the frontend build alongside server/ for Rails.
set :deploy_to, "/opt/caramba"

# mise manages Ruby — tell Capistrano to use mise shims for all commands
# The shims directory must come FIRST in PATH to take precedence over system Ruby
set :default_env, {
  path: "~/.local/share/mise/shims:$PATH"
}

# Bundler runs inside the server/ subdirectory
set :bundle_gemfile, -> { release_path.join("server", "Gemfile") }
set :bundle_path, -> { shared_path.join("bundle") }
set :bundle_flags, "--quiet"

# Rails paths are relative to server/
set :rails_env, "production"
set :migration_role, :app

# Shared paths — persist across deploys
append :linked_dirs,
  "server/storage",        # SQLite DBs + Active Storage uploads
  "server/log",
  "server/tmp/pids",
  "server/tmp/cache",
  "server/tmp/sockets",
  "server/vendor/bundle",
  "node_modules",          # pnpm store (shared across deploys)
  "web/node_modules"

append :linked_files,
  "server/config/master.key"

# Keep 5 releases for quick rollback
set :keep_releases, 5

# Puma PID file location
set :puma_pid, -> { shared_path.join("server", "tmp", "pids", "puma.pid") }

# launchd service label
set :launchd_label, "com.caramba.server"
set :launchd_plist, -> { File.expand_path("~/Library/LaunchAgents/#{fetch(:launchd_label)}.plist") }

# =============================================================================
# Override default Rails tasks to run inside server/ subdirectory
# =============================================================================

# Verify Ruby version before deployment
namespace :deploy do
  task :check_ruby do
    on primary(:app) do
      with default_env do
        ruby_version = capture(:ruby, "--version")
        puts "Ruby version: #{ruby_version}"
        raise "Ruby 4.x required!" unless ruby_version.include?("4.")
      end
    end
  end
end

before "deploy:started", "deploy:check_ruby"

Rake::Task["deploy:migrate"].clear_actions
namespace :deploy do
  desc "Run Rails db:prepare in server/"
  task :migrate do
    on primary(:app) do
      within release_path.join("server") do
        with rails_env: fetch(:rails_env) do
          execute :bundle, "exec rails db:prepare"
        end
      end
    end
  end
end

Rake::Task["deploy:assets:precompile"].clear_actions
namespace :deploy do
  namespace :assets do
    desc "Build React web app into server/public/"
    task :precompile do
      on roles(:app) do
        within release_path do
          # Install pnpm dependencies
          execute :pnpm, "install --frozen-lockfile"

          # Build the web app — output goes to web/dist/
          execute :pnpm, "--filter web exec vite build"

          # Copy built assets into server/public/ so Rails serves them
          execute :cp, "-r web/dist/* server/public/"
        end
      end
    end
  end
end
