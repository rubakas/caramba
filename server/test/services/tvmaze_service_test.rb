require "test_helper"

class TvmazeServiceTest < ActiveSupport::TestCase
  setup do
    @search_shows_response = [
      {
        "score" => 0.9,
        "show" => {
          "id" => 169,
          "name" => "Breaking Bad",
          "image" => { "original" => "https://img.tvmaze.com/bb.jpg", "medium" => "https://img.tvmaze.com/bb_m.jpg" },
          "summary" => "<p>A high school chemistry teacher.</p>",
          "genres" => [ "Drama", "Crime" ],
          "rating" => { "average" => 9.5 },
          "premiered" => "2008-01-20",
          "status" => "Ended",
          "network" => { "name" => "AMC" },
          "webChannel" => nil,
          "externals" => { "imdb" => "tt0903747" },
          "type" => "Scripted",
          "language" => "English",
          "runtime" => 60,
          "averageRuntime" => 60,
          "schedule" => { "time" => "22:00", "days" => [ "Sunday" ] },
          "officialSite" => "http://www.amc.com/shows/breaking-bad"
        }
      }
    ].to_json

    @singlesearch_response = {
      "id" => 169,
      "name" => "Breaking Bad",
      "image" => { "original" => "https://img.tvmaze.com/bb.jpg" },
      "summary" => "<p>A high school chemistry teacher.</p>",
      "genres" => [ "Drama", "Crime" ],
      "rating" => { "average" => 9.5 },
      "premiered" => "2008-01-20",
      "status" => "Ended",
      "externals" => { "imdb" => "tt0903747" },
      "_embedded" => {
        "episodes" => [
          {
            "id" => 1,
            "season" => 1,
            "number" => 1,
            "name" => "Pilot",
            "airdate" => "2008-01-20",
            "runtime" => 58,
            "summary" => "<p>Walter White starts cooking.</p>"
          },
          {
            "id" => 2,
            "season" => 1,
            "number" => 2,
            "name" => "Cat's in the Bag...",
            "airdate" => "2008-01-27",
            "runtime" => 48,
            "summary" => "<p>Walt and Jesse deal with aftermath.</p>"
          }
        ]
      }
    }.to_json

    @show_details_response = @singlesearch_response
  end

  test "search_shows returns mapped show hashes" do
    stub_request(:get, /api\.tvmaze\.com\/search\/shows/)
      .to_return(status: 200, body: @search_shows_response, headers: { "Content-Type" => "application/json" })

    results = TvmazeService.search_shows("breaking bad")
    assert_equal 1, results.size

    show = results.first
    assert_equal "show", show["_type"]
    assert_equal 169, show["tvmaze_id"]
    assert_equal "Breaking Bad", show["name"]
    assert_equal "Drama, Crime", show["genres"]
    assert_equal 9.5, show["rating"]
    assert_equal 0.9, show["score"]
    assert_equal "AMC", show["network"]
    assert_equal "tt0903747", show["imdb_id"]
  end

  test "search_shows returns empty array on error" do
    stub_request(:get, /api\.tvmaze\.com\/search\/shows/)
      .to_return(status: 500)

    assert_equal [], TvmazeService.search_shows("anything")
  end

  test "show_details returns show + episodes + seasons" do
    stub_request(:get, /api\.tvmaze\.com\/shows\/169/)
      .to_return(status: 200, body: @show_details_response, headers: { "Content-Type" => "application/json" })

    result = TvmazeService.show_details(169)
    assert_not_nil result
    assert_equal "Breaking Bad", result["show"]["name"]
    assert_equal 2, result["episodes"].size
    assert result["seasons"].key?(1)
    assert_equal 2, result["seasons"][1].size
  end

  test "show_details returns nil on 404" do
    stub_request(:get, /api\.tvmaze\.com\/shows\/999/)
      .to_return(status: 404)

    assert_nil TvmazeService.show_details(999)
  end

  test "fetch_for_show updates show and episodes" do
    stub_request(:get, /api\.tvmaze\.com\/singlesearch/)
      .to_return(status: 200, body: @singlesearch_response, headers: { "Content-Type" => "application/json" })

    bb = shows(:breaking_bad)
    # Clear existing metadata to verify it gets set
    bb.update_columns(tvmaze_id: nil, poster_url: nil, description: nil)

    result = TvmazeService.fetch_for_show(bb)
    assert result

    bb.reload
    assert_equal 169, bb.tvmaze_id
    assert_equal "https://img.tvmaze.com/bb.jpg", bb.poster_url
    assert_equal "A high school chemistry teacher.", bb.description
    assert_equal "Drama, Crime", bb.genres

    # Check episode metadata was updated
    ep1 = episodes(:bb_s01e01).reload
    assert_equal 1, ep1.tvmaze_id
    assert_equal "2008-01-20", ep1.air_date
    assert_equal 58, ep1.runtime
  end

  test "fetch_for_show returns false on API failure" do
    stub_request(:get, /api\.tvmaze\.com\/singlesearch/)
      .to_return(status: 404)

    assert_not TvmazeService.fetch_for_show(shows(:breaking_bad))
  end

  test "handles rate limiting with retry" do
    stub_request(:get, /api\.tvmaze\.com\/search\/shows/)
      .to_return(status: 429, headers: { "retry-after" => "0" })
      .then.to_return(status: 200, body: @search_shows_response, headers: { "Content-Type" => "application/json" })

    results = TvmazeService.search_shows("breaking bad")
    assert_equal 1, results.size
  end
end
