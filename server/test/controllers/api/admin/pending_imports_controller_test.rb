require "test_helper"

class Api::Admin::PendingImportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @dir = Dir.mktmpdir
    @folder = MediaFolder.create!(path: @dir, kind: "series")
  end

  teardown do
    FileUtils.remove_entry(@dir) if @dir
  end

  test "index returns all pending imports as camelCase json" do
    pi = PendingImport.create!(
      media_folder: @folder,
      folder_path: "#{@dir}/Breaking Bad",
      kind: "series",
      parsed_name: "Breaking Bad",
      candidates: [ { "externalId" => 169, "name" => "Breaking Bad", "source" => "tvmaze" } ]
    )

    get "/api/admin/pending_imports"
    assert_response :success
    body = JSON.parse(response.body)
    entry = body.find { |e| e["id"] == pi.id }
    assert_not_nil entry
    assert_equal "series", entry["kind"]
    assert_equal "Breaking Bad", entry["parsedName"]
    assert_equal "pending", entry["status"]
    assert_equal 1, entry["candidates"].size
    assert_equal 169, entry["candidates"].first["externalId"]
    assert_equal @folder.id, entry["mediaFolderId"]
  end

  test "index filters by status" do
    PendingImport.create!(media_folder: @folder, folder_path: "#{@dir}/Pending", kind: "series")
    PendingImport.create!(media_folder: @folder, folder_path: "#{@dir}/Confirmed", kind: "series", status: "confirmed")

    get "/api/admin/pending_imports", params: { status: "pending" }
    assert_response :success
    body = JSON.parse(response.body)
    # Should not include the confirmed one we just created (but may include fixture's pending ones)
    statuses = body.map { |e| e["status"] }.uniq
    assert_equal [ "pending" ], statuses
  end

  test "index orders by created_at desc" do
    older = PendingImport.create!(media_folder: @folder, folder_path: "#{@dir}/Older", kind: "series", created_at: 1.day.ago)
    newer = PendingImport.create!(media_folder: @folder, folder_path: "#{@dir}/Newer", kind: "series", created_at: 1.hour.ago)

    get "/api/admin/pending_imports"
    body = JSON.parse(response.body)
    ids = body.map { |e| e["id"] }
    assert ids.index(newer.id) < ids.index(older.id), "newer should precede older"
  end

  test "confirm creates a Series and returns it" do
    show_dir = File.join(@dir, "Breaking Bad (2008)")
    Dir.mkdir(show_dir)
    pi = PendingImport.create!(
      media_folder: @folder,
      folder_path: show_dir,
      kind: "series",
      parsed_name: "Breaking Bad",
      candidates: [ { "externalId" => 169, "name" => "Breaking Bad" } ]
    )
    stub_request(:get, %r{api\.tvmaze\.com/shows/169}).to_return(
      status: 200,
      body: { id: 169, name: "Breaking Bad", image: { original: "https://example.com/bb.jpg" }, summary: "", genres: [], rating: { average: 9.5 }, premiered: "2008-01-20", status: "Ended", externals: { imdb: "tt0903747" }, _embedded: { episodes: [] } }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    assert_difference("Series.count", 1) do
      post "/api/admin/pending_imports/#{pi.id}/confirm", params: { externalId: 169 }
    end
    assert_response :created
    body = JSON.parse(response.body)
    assert body["series"].is_a?(Hash)
    assert_equal "Breaking Bad", body["series"]["name"]
    assert_equal 169, body["series"]["tvmaze_id"]
    assert_equal "confirmed", pi.reload.status
  end

  test "confirm without externalId returns 422" do
    pi = PendingImport.create!(media_folder: @folder, folder_path: "#{@dir}/show", kind: "series")
    post "/api/admin/pending_imports/#{pi.id}/confirm"
    assert_response :unprocessable_entity
  end

  test "ignore marks pending_import ignored" do
    pi = PendingImport.create!(media_folder: @folder, folder_path: "#{@dir}/show", kind: "series")
    post "/api/admin/pending_imports/#{pi.id}/ignore"
    assert_response :no_content
    assert_equal "ignored", pi.reload.status
  end

  test "research re-runs the TVMaze search and replaces candidates" do
    pi = PendingImport.create!(
      media_folder: @folder,
      folder_path: "#{@dir}/show",
      kind: "series",
      parsed_name: "Breaking Bad",
      candidates: [ { "externalId" => 1, "name" => "Stale" } ],
      status: "failed",
      error: "old error"
    )
    stub_request(:get, %r{api\.tvmaze\.com/search/shows}).to_return(
      status: 200,
      body: [ { score: 9.9, show: { id: 169, name: "Breaking Bad", image: nil, summary: "", genres: [], rating: { average: 9.5 }, premiered: "2008-01-20", status: "Ended", externals: { imdb: "tt0903747" } } } ].to_json,
      headers: { "Content-Type" => "application/json" }
    )

    post "/api/admin/pending_imports/#{pi.id}/research"
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "pending", body["status"]
    assert_nil body["error"]
    assert_equal 169, body["candidates"].first["externalId"]
  end
end
