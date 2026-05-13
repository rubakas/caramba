require 'rails/generators'
require 'securerandom'

module Jellyfin
  module Generators
    # `rails g jellyfin:install`
    #
    # Writes a configured initializer + mounts the engine in routes.rb.
    class InstallGenerator < ::Rails::Generators::Base
      source_root File.expand_path('templates', __dir__)

      desc 'Install jellyfin-rails: write initializer + mount engine'

      class_option :mount, type: :string, default: '/jellyfin',
                   desc: 'Path to mount the engine at'

      def create_initializer
        template 'initializer.rb.tt', 'config/initializers/jellyfin.rb'
      end

      def mount_engine
        route_line = "mount Jellyfin::Rails::Engine => '#{options[:mount]}'"
        routes_file = 'config/routes.rb'
        if File.exist?(routes_file) && !File.read(routes_file).include?('Jellyfin::Rails::Engine')
          route route_line
        end
      end

      def show_next_steps
        say "\n  jellyfin-rails installed.", :green
        say "  • Initializer:    config/initializers/jellyfin.rb"
        say "  • Engine mounted: #{options[:mount]}"
        say "\n  Next steps:"
        say "    1. Install jellyfin-ffmpeg and set c.ffmpeg_path"
        say "    2. Set c.allowed_paths to your media folders"
        say "    3. curl http://localhost:3000#{options[:mount]}/_status to verify"
      end
    end
  end
end
