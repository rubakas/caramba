require 'rails'
require 'action_controller/railtie'

require 'jellyfin-rails'

module Dummy
  class Application < ::Rails::Application
    config.root = File.expand_path('..', __dir__)
    config.load_defaults ::Rails::VERSION::STRING.to_f
    config.eager_load = false
    config.logger = Logger.new(IO::NULL)
    config.secret_key_base = 'test' * 16
    config.hosts.clear if config.respond_to?(:hosts) && config.hosts.respond_to?(:clear)
    config.action_dispatch.show_exceptions = :none
    config.consider_all_requests_local = true
  end
end
