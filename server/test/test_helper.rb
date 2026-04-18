ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "webmock/minitest"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Stub every outgoing request for an image URL so Posterable#download_poster!
    # doesn't need to be wired up per-test. Metadata service tests that care
    # about the image bytes can override with their own stub_request.
    setup do
      WebMock.stub_request(:get, %r{\.(jpg|jpeg|png|gif|webp)(\?.*)?\z}i)
        .to_return(status: 200, body: "\xFF\xD8\xFF".b, headers: { "Content-Type" => "image/jpeg" })
    end
  end
end
