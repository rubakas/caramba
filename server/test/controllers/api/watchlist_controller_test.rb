require "test_helper"

class Api::WatchlistControllerTest < ActionDispatch::IntegrationTest
  test "index returns watchlist items with flags" do
    get "/api/watchlist"
    assert_response :success

    data = JSON.parse(response.body)
    assert_kind_of Array, data
    assert data.size >= 2

    show = data.find { |i| i["_type"] == "show" }
    assert_not_nil show
    assert show.key?("in_library")
    assert show.key?("library_slug")
    assert show.key?("in_watchlist")
    assert_equal true, show["in_watchlist"]

    movie = data.find { |i| i["_type"] == "movie" }
    assert_not_nil movie
  end

  test "create adds show to watchlist" do
    post "/api/watchlist", params: {
      _type: "show",
      tvmaze_id: 9999,
      name: "Test Show",
      poster_url: "https://example.com/test.jpg"
    }
    assert_response :success

    data = JSON.parse(response.body)
    assert data["success"]
    assert Watchlist.find_by(tvmaze_id: 9999)
  end

  test "create adds movie to watchlist" do
    post "/api/watchlist", params: {
      _type: "movie",
      imdb_id: "tt9999999",
      name: "Test Movie",
      year: "2024"
    }
    assert_response :success

    data = JSON.parse(response.body)
    assert data["success"]
    assert Watchlist.find_by(imdb_id: "tt9999999")
  end

  test "create show without tvmaze_id returns 422" do
    post "/api/watchlist", params: { _type: "show", name: "No ID" }
    assert_response :unprocessable_entity
  end

  test "create movie without imdb_id returns 422" do
    post "/api/watchlist", params: { _type: "movie", name: "No ID" }
    assert_response :unprocessable_entity
  end

  test "create is idempotent for same tvmaze_id" do
    existing = watchlist(:watchlist_show)
    assert_no_difference "Watchlist.count" do
      post "/api/watchlist", params: {
        _type: "show",
        tvmaze_id: existing.tvmaze_id,
        name: "Whatever"
      }
    end
    assert_response :success
  end

  test "destroy by id" do
    item = watchlist(:watchlist_show)
    delete "/api/watchlist/#{item.id}"
    assert_response :success
    assert_nil Watchlist.find_by(id: item.id)
  end

  test "destroy by tvmaze_id" do
    item = watchlist(:watchlist_show)
    delete "/api/watchlist/0", params: { tvmaze_id: item.tvmaze_id }
    assert_response :success
    assert_nil Watchlist.find_by(tvmaze_id: item.tvmaze_id)
  end

  test "destroy by imdb_id" do
    item = watchlist(:watchlist_movie)
    delete "/api/watchlist/0", params: { imdb_id: item.imdb_id }
    assert_response :success
    assert_nil Watchlist.find_by(imdb_id: item.imdb_id)
  end
end
