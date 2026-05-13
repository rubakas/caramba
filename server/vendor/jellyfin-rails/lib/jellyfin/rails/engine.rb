require 'rails/engine'

module Jellyfin
  module Rails
    class Engine < ::Rails::Engine
      isolate_namespace Jellyfin

      config.generators do |g|
        g.test_framework :rspec
      end

      initializer 'jellyfin.rails.autoload', before: :set_autoload_paths do |app|
        app.config.autoload_paths += Dir[root.join('app', '**')]
      end

      initializer 'jellyfin.rails.helpers' do
        ActiveSupport.on_load(:action_view) do
          include Jellyfin::PlayerHelper
        end
      end

    end
  end
end
