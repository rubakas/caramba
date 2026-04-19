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

    # Use a small static image from the repo so the parent test process does
    # not initialize libvips before Rails forks parallel workers.
    FAKE_JPEG = Rails.root.join("public/icon.png").binread.freeze

    # Stub every outgoing request for an image URL so Posterable#download_poster!
    # doesn't need to be wired up per-test. Tests that care about specific
    # bytes or status codes can override with their own stub_request.
    setup do
      WebMock.stub_request(:get, %r{\.(jpg|jpeg|png|gif|webp)(\?.*)?\z}i)
        .to_return(status: 200, body: FAKE_JPEG, headers: { "Content-Type" => "image/jpeg" })
    end
  end
end
