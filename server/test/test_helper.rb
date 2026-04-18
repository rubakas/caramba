ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "webmock/minitest"
require "vips"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # A minimal real JPEG — Posterable pipes every downloaded image through
    # libvips to resize it, so the stub bytes have to be a decodable JPEG.
    FAKE_JPEG = Vips::Image.black(4, 4).cast(:uchar).bandjoin([ 0, 0 ]).copy(interpretation: :srgb).write_to_buffer(".jpg").freeze

    # Stub every outgoing request for an image URL so Posterable#download_poster!
    # doesn't need to be wired up per-test. Tests that care about specific
    # bytes or status codes can override with their own stub_request.
    setup do
      WebMock.stub_request(:get, %r{\.(jpg|jpeg|png|gif|webp)(\?.*)?\z}i)
        .to_return(status: 200, body: FAKE_JPEG, headers: { "Content-Type" => "image/jpeg" })
    end
  end
end
