require "test_helper"

class Api::DiscoverControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tvmaze_search = [
      {
        "score" => 0.9,
        "show" => {
          "id" => 169,
          "name" => "Breaking Bad",
          "image" => { "original" => "https://img.tvmaze.com/bb.jpg" },
          "summary" => "<p>Chemistry teacher.</p>",
          "genres" => [ "Drama" ],
          "rating" => { "average" => 9.5 },
          "premiered" => "2008-01-20",
          "status" => "Ended",
          "network" => { "name" => "AMC" },
          "webChannel" => nil,
          "externals" => { "imdb" => "tt0903747" },
          "type" => "Scripted",
          "language" => "English",
          "runtime" => 60,
          "averageRuntime" => nil,
          "schedule" => nil,
          "officialSite" => nil
        }
      }
    ].to_json

    @imdb_search = {
      "titles" => [
        {
          "id" => "tt0133093",
          "primaryTitle" => "The Matrix",
          "type" => "movie",
          "startYear" => 1999,
          "primaryImage" => { "url" => "https://img.imdb.com/matrix.jpg" },
          "rating" => { "aggregateRating" => 8.7 }
        }
      ]
    }.to_json

    @show_details_response = {
      "id" => 169,
      "name" => "Breaking Bad",
      "image" => { "original" => "https://img.tvmaze.com/bb.jpg" },
      "summary" => "<p>Chemistry teacher.</p>",
      "genres" => [ "Drama" ],
      "rating" => { "average" => 9.5 },
      "premiered" => "2008-01-20",
      "status" => "Ended",
      "network" => { "name" => "AMC" },
      "webChannel" => nil,
      "externals" => { "imdb" => "tt0903747" },
      "type" => "Scripted",
      "language" => "English",
      "runtime" => 60,
      "averageRuntime" => nil,
      "schedule" => nil,
      "officialSite" => nil,
      "_embedded" => {
        "episodes" => [
          { "id" => 1, "season" => 1, "number" => 1, "name" => "Pilot", "airdate" => "2008-01-20", "runtime" => 58, "summary" => nil }
        ]
      }
    }.to_json

    @movie_details_response = {
      "id" => "tt0133093",
      "plot" => "Hacker discovers reality.",
      "genres" => [ "Action" ],
      "directors" => [ { "displayName" => "Wachowski" } ],
      "runtimeSeconds" => 8160,
      "startYear" => 1999,
      "rating" => { "aggregateRating" => 8.7 },
      "primaryImage" => { "url" => "https://img.imdb.com/matrix.jpg" }
    }.to_json
  end

  test "search returns shows and movies" do
    stub_request(:get, /api\.tvmaze\.com\/search\/shows/)
      .to_return(status: 200, body: @tvmaze_search, headers: { "Content-Type" => "application/json" })
    stub_request(:get, /api\.imdbapi\.dev\/search\/titles/)
      .to_return(status: 200, body: @imdb_search, headers: { "Content-Type" => "application/json" })

    get "/api/discover/search", params: { q: "breaking bad" }
    assert_response :success

    data = JSON.parse(response.body)
    assert data.key?("shows")
    assert data.key?("movies")
    assert data["shows"].size >= 1
    assert data["movies"].size >= 1

    show = data["shows"].first
    assert show.key?("in_library")
    assert show.key?("in_watchlist")
  end

  test "search returns empty for short query" do
    get "/api/discover/search", params: { q: "a" }
    assert_response :success

    data = JSON.parse(response.body)
    assert_empty data["shows"]
    assert_empty data["movies"]
  end

  test "search with type=shows only searches shows" do
    stub_request(:get, /api\.tvmaze\.com\/search\/shows/)
      .to_return(status: 200, body: @tvmaze_search, headers: { "Content-Type" => "application/json" })

    get "/api/discover/search", params: { q: "breaking", type: "shows" }
    assert_response :success

    data = JSON.parse(response.body)
    assert data["shows"].size >= 1
    assert_empty data["movies"]
  end

  test "show_details returns show with episodes and seasons" do
    stub_request(:get, /api\.tvmaze\.com\/shows\/169/)
      .to_return(status: 200, body: @show_details_response, headers: { "Content-Type" => "application/json" })

    get "/api/discover/show_details", params: { tvmaze_id: 169 }
    assert_response :success

    data = JSON.parse(response.body)
    assert_equal "Breaking Bad", data["show"]["name"]
    assert data["episodes"].size >= 1
    assert data["seasons"].key?("1")
  end

  test "show_details returns null without tvmaze_id" do
    get "/api/discover/show_details"
    assert_response :success
    assert_equal "null", response.body.strip
  end

  test "movie_details returns movie detail" do
    stub_request(:get, /api\.imdbapi\.dev\/titles\/tt0133093/)
      .to_return(status: 200, body: @movie_details_response, headers: { "Content-Type" => "application/json" })

    get "/api/discover/movie_details", params: { imdb_id: "tt0133093" }
    assert_response :success

    data = JSON.parse(response.body)
    assert_equal "tt0133093", data["imdb_id"]
    assert_includes data["description"], "Hacker"
  end

  test "movie_details returns null without imdb_id" do
    get "/api/discover/movie_details"
    assert_response :success
    assert_equal "null", response.body.strip
  end
end
