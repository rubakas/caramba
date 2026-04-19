require "test_helper"

class Api::Admin::ScansControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  test "POST /api/admin/scan enqueues LibraryScanJob and returns accepted" do
    assert_enqueued_with(job: LibraryScanJob) do
      post "/api/admin/scan"
    end
    assert_response :accepted
    body = JSON.parse(response.body)
    assert_equal true, body["enqueued"]
  end
end
