require "test_helper"

class Api::SeriesControllerTest < ActionDispatch::IntegrationTest
  test "index returns all series with counts" do
    get "/api/series"
    assert_response :success

    data = JSON.parse(response.body)
    assert_kind_of Array, data
    assert data.size >= 2

    bb = data.find { |s| s["slug"] == "breaking-bad" }
    assert_not_nil bb
    assert_equal "Breaking Bad", bb["name"]
    assert bb.key?("total_episodes")
    assert bb.key?("watched_episodes")
    assert bb.key?("season_count")
  end

  test "show returns series by slug" do
    get "/api/series/breaking-bad"
    assert_response :success

    data = JSON.parse(response.body)
    assert_equal "Breaking Bad", data["name"]
    assert_equal "breaking-bad", data["slug"]
  end

  test "show returns 404 for unknown slug" do
    get "/api/series/nonexistent"
    assert_response :not_found
  end

  test "full returns combined data" do
    get "/api/series/breaking-bad/full"
    assert_response :success

    data = JSON.parse(response.body)
    assert data.key?("series")
    assert data.key?("episodes")
    assert data.key?("seasons")
    assert data.key?("resumeEp")
    assert data.key?("nextEp")

    assert_equal "Breaking Bad", data["series"]["name"]
    assert_kind_of Array, data["episodes"]
    assert_kind_of Array, data["seasons"]
  end

  test "episodes returns episodes for series" do
    get "/api/series/breaking-bad/episodes"
    assert_response :success

    data = JSON.parse(response.body)
    assert_kind_of Array, data
    assert data.size >= 3
  end

  test "seasons returns season numbers" do
    get "/api/series/breaking-bad/seasons"
    assert_response :success

    data = JSON.parse(response.body)
    assert_includes data, 1
    assert_includes data, 2
  end

  test "resumable returns partially watched episode" do
    get "/api/series/breaking-bad/resumable"
    assert_response :success

    data = JSON.parse(response.body)
    # bb_s01e02 has progress 1200/2880 < 0.9
    assert_not_nil data
    assert_equal "S01E02", data["code"]
  end

  test "next_up returns next unwatched episode" do
    get "/api/series/breaking-bad/next_up"
    assert_response :success

    data = JSON.parse(response.body)
    assert_not_nil data
    # After S01E01 (watched), next should be S01E02
    assert_equal "S01E02", data["code"]
  end

  test "create with folder_path creates series and scans" do
    Dir.mktmpdir do |dir|
      season_dir = File.join(dir, "Season 1")
      FileUtils.mkdir_p(season_dir)
      FileUtils.touch(File.join(season_dir, "Show.S01E01.Pilot.mkv"))

      stub_request(:get, /api\.tvmaze\.com\/singlesearch/)
        .to_return(status: 404)

      post "/api/series", params: { folder_path: dir }
      assert_response :created

      data = JSON.parse(response.body)
      assert data["name"].present?
      assert data["slug"].present?
    end
  end

  test "create without folder_path returns 422" do
    post "/api/series", params: {}
    assert_response :unprocessable_entity
  end

  test "scan rescans series" do
    bb = series(:breaking_bad)
    # media_path doesn't exist on disk, so scan returns 0
    post "/api/series/breaking-bad/scan"
    assert_response :success

    data = JSON.parse(response.body)
    assert data.key?("scanned")
  end

  test "refresh_metadata calls TvmazeService" do
    stub_request(:get, /api\.tvmaze\.com\/singlesearch/)
      .to_return(status: 404)

    post "/api/series/breaking-bad/refresh_metadata"
    assert_response :success

    data = JSON.parse(response.body)
    assert data.key?("success")
  end

  test "destroy removes series" do
    s = Series.create!(name: "To Delete", media_path: "/tmp/del")
    delete "/api/series/#{s.slug}"
    assert_response :no_content
    assert_nil Series.find_by(slug: s.slug)
  end
end
