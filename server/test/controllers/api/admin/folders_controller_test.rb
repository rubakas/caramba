require "test_helper"

class Api::Admin::FoldersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @dir = Dir.mktmpdir
  end

  teardown do
    FileUtils.remove_entry(@dir) if @dir
  end

  test "index returns folders as camelCase json" do
    MediaFolder.create!(path: @dir, kind: "series")
    get "/api/admin/folders"
    assert_response :success
    body = JSON.parse(response.body)
    assert body.is_a?(Array)
    entry = body.find { |f| f["path"] == @dir }
    assert_not_nil entry
    assert_equal "series", entry["kind"]
    assert_equal true, entry["enabled"]
    assert entry.key?("lastScannedAt")
  end

  test "create persists a folder" do
    assert_difference("MediaFolder.count", 1) do
      post "/api/admin/folders", params: { path: @dir, kind: "movies" }
    end
    assert_response :created
    body = JSON.parse(response.body)
    assert_equal @dir, body["path"]
    assert_equal "movies", body["kind"]
  end

  test "create rejects invalid kind" do
    post "/api/admin/folders", params: { path: @dir, kind: "anime" }
    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_match(/not included/i, body["error"])
  end

  test "create rejects non-existent path" do
    post "/api/admin/folders", params: { path: "/does/not/exist/#{SecureRandom.hex}", kind: "series" }
    assert_response :unprocessable_entity
  end

  test "create rejects duplicate path" do
    MediaFolder.create!(path: @dir, kind: "series")
    post "/api/admin/folders", params: { path: @dir, kind: "movies" }
    assert_response :unprocessable_entity
  end

  test "update toggles enabled" do
    folder = MediaFolder.create!(path: @dir, kind: "series", enabled: true)
    patch "/api/admin/folders/#{folder.id}", params: { enabled: false }
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal false, body["enabled"]
    assert_equal false, folder.reload.enabled
  end

  test "update ignores path/kind changes" do
    folder = MediaFolder.create!(path: @dir, kind: "series")
    patch "/api/admin/folders/#{folder.id}", params: { path: "/other", kind: "movies" }
    assert_response :success
    folder.reload
    assert_equal @dir, folder.path
    assert_equal "series", folder.kind
  end

  test "destroy removes a folder" do
    folder = MediaFolder.create!(path: @dir, kind: "series")
    assert_difference("MediaFolder.count", -1) do
      delete "/api/admin/folders/#{folder.id}"
    end
    assert_response :no_content
  end

  test "destroy returns 404 when missing" do
    delete "/api/admin/folders/9999999"
    assert_response :not_found
  end
end
