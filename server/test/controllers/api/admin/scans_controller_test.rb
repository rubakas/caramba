require "test_helper"

class Api::Admin::ScansControllerTest < ActionDispatch::IntegrationTest
  test "POST /api/admin/scan runs scan inline and returns counts" do
    Dir.mktmpdir do |root|
      Dir.mkdir(File.join(root, "Some Show"))
      MediaFolder.create!(path: root, kind: "shows")
      stub_request(:get, %r{api\.tvmaze\.com/search/shows}).to_return(
        status: 200, body: "[]", headers: { "Content-Type" => "application/json" }
      )

      post "/api/admin/scan"
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal true, body["ok"]
      assert body["created"].is_a?(Integer)
      assert body["pending"].is_a?(Integer)
      assert_operator body["created"], :>=, 1
    end
  end

  test "POST /api/admin/scan with no enabled folders returns zero" do
    MediaFolder.where(enabled: true).update_all(enabled: false)
    post "/api/admin/scan"
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 0, body["created"]
  end
end
