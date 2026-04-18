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
    assert bb.key?("has_continue")
  end

  test "show returns series by slug" do
    get "/api/series/breaking-bad"
    assert_response :success

    data = JSON.parse(response.body)
    assert_equal "Breaking Bad", data["name"]
    assert_equal "breaking-bad", data["slug"]
  end

  test "poster_url points at the Rails proxy when an image is attached" do
    series = series(:breaking_bad)
    series.poster.attach(
      io: StringIO.new("\xFF\xD8\xFFbytes".b),
      filename: "bb.jpg",
      content_type: "image/jpeg"
    )

    get "/api/series/breaking-bad"
    data = JSON.parse(response.body)

    assert_match(%r{/rails/active_storage/representations/proxy/.+/bb\.jpg\z}, data["poster_url"])
  end

  test "poster_url falls back to the external URL when no image is attached" do
    series(:breaking_bad).poster.detach

    get "/api/series/breaking-bad"
    data = JSON.parse(response.body)

    assert_equal "https://example.com/bb.jpg", data["poster_url"]
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
    assert data.key?("continue")
    assert data["continue"].key?("mode")
    assert data["continue"].key?("episode")

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

  test "continue returns resume when last played is unfinished" do
    # bb_s01e02 was last_played 1 day ago (more recent than bb_s01e01 at 2 days)
    # and has progress 1200/2880 < 0.9 → unfinished
    get "/api/series/breaking-bad/continue"
    assert_response :success

    data = JSON.parse(response.body)
    assert_equal "resume", data["mode"]
    assert_equal "S01E02", data["episode"]["code"]
  end

  test "continue returns next when last played is finished and a later episode exists" do
    # Move S01E02 to fully watched and more recently played than S01E01
    ep = episodes(:bb_s01e02)
    ep.update!(watched: 1, progress_seconds: 2880, duration_seconds: 2880, last_watched_at: Time.current)

    get "/api/series/breaking-bad/continue"
    assert_response :success

    data = JSON.parse(response.body)
    assert_equal "next", data["mode"]
    # S02E01 is the only episode after S01E02
    assert_equal "S02E01", data["episode"]["code"]
  end

  test "continue does not suggest older unfinished episode after a later one was played" do
    # Recreate the bug scenario: S01E02 unfinished (touched 1 day ago),
    # then user played S02E01 to completion just now.
    ep = episodes(:bb_s02e01)
    ep.update!(watched: 1, progress_seconds: 3000, duration_seconds: 3000, last_watched_at: Time.current)

    get "/api/series/breaking-bad/continue"
    assert_response :success

    data = JSON.parse(response.body)
    # Should NOT resume the stale S01E02; there's no episode after S02E01 so we're done.
    assert_equal "done", data["mode"]
    assert_nil data["episode"]
  end

  test "continue returns start when nothing has been played or watched" do
    get "/api/series/the-office/continue"
    assert_response :success

    data = JSON.parse(response.body)
    assert_equal "start", data["mode"]
    assert_equal "S01E01", data["episode"]["code"]
  end

  test "continue returns empty for a series with no episodes" do
    get "/api/series/new-show/continue"
    assert_response :success

    data = JSON.parse(response.body)
    assert_equal "empty", data["mode"]
    assert_nil data["episode"]
  end

  test "continue resumes an episode after only a few seconds of playback" do
    # Regression: clicking play used to eagerly mark an episode watched,
    # so after 3s of playback `continue` would suggest the NEXT episode
    # instead of resuming the one still in progress.
    ep = episodes(:bb_s02e01)
    Tempfile.create([ "episode", ".mkv" ]) do |f|
      ep.update!(file_path: f.path, watched: 0, progress_seconds: 0, duration_seconds: 0, last_watched_at: nil)

      post "/api/episodes/#{ep.id}/play"
      assert_response :success

      # Simulate a report_progress after 3 seconds of a ~48min episode
      post "/api/playback/report_progress", params: { episode_id: ep.id, time: 3, duration: 2880 }
      assert_response :success

      get "/api/series/breaking-bad/continue"
      data = JSON.parse(response.body)
      assert_equal "resume", data["mode"]
      assert_equal "S02E01", data["episode"]["code"]
    end
  end

  test "index marks has_continue for a started series and not for an untouched one" do
    get "/api/series"
    assert_response :success
    data = JSON.parse(response.body)

    bb = data.find { |s| s["slug"] == "breaking-bad" }
    office = data.find { |s| s["slug"] == "the-office" }

    assert_equal true, bb["has_continue"]     # S01E02 is mid-playback
    assert_equal false, office["has_continue"] # nothing watched → start mode
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
