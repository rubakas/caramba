ENV['RAILS_ENV'] ||= 'test'

require File.expand_path('dummy/config/environment', __dir__)
require 'rspec/rails'
require 'rack/test'

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.disable_monkey_patching!
  config.warnings = false
  config.default_formatter = 'doc' if config.files_to_run.one?
  config.order = :random
  Kernel.srand config.seed

  config.before(:each) do
    Jellyfin::Rails.reset_configuration!
    Jellyfin::MediaEncoder::Encoder.reset! if defined?(Jellyfin::MediaEncoder::Encoder)
  end
end

FIXTURE_PATH = File.expand_path('fixtures', __dir__)
