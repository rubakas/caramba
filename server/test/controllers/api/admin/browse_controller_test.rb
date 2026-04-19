require "test_helper"

class Api::Admin::BrowseControllerTest < ActionDispatch::IntegrationTest
  setup do
    @root = Dir.mktmpdir
    Dir.mkdir(File.join(@root, "A_show"))
    Dir.mkdir(File.join(@root, "Z_show"))
    File.write(File.join(@root, "ignored.txt"), "file")
  end

  teardown do
    FileUtils.remove_entry(@root) if @root
  end

  test "returns mounts when path blank" do
    get "/api/admin/browse"
    assert_response :success
    body = JSON.parse(response.body)
    assert_nil body["path"]
    assert_nil body["parent"]
    assert_equal [], body["entries"]
    assert body["mounts"].is_a?(Array)
    assert body["mounts"].any? { |m| m["name"] == "Home" }
  end

  test "returns directory entries for a valid path" do
    get "/api/admin/browse", params: { path: @root }
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal File.realpath(@root), body["path"]
    assert_equal [ "A_show", "Z_show" ], body["entries"].map { |e| e["name"] }
    assert_equal [], body["mounts"]
    assert_not_nil body["parent"]
  end

  test "returns 422 for relative path" do
    get "/api/admin/browse", params: { path: "relative/thing" }
    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_match(/absolute/, body["error"])
  end

  test "returns 422 for non-existent path" do
    get "/api/admin/browse", params: { path: "/does/not/exist/#{SecureRandom.hex}" }
    assert_response :unprocessable_entity
  end

  test "returns 422 for symlink escaping to forbidden root" do
    sneaky = File.join(@root, "escape")
    File.symlink("/etc", sneaky)
    get "/api/admin/browse", params: { path: sneaky }
    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_match(/not permitted/, body["error"])
  end
end
