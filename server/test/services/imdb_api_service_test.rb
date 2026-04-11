require "test_helper"

class ImdbApiServiceTest < ActiveSupport::TestCase
  setup do
    @search_response = {
      "titles" => [
        {
          "id" => "tt0133093",
          "primaryTitle" => "The Matrix",
          "originalTitle" => "The Matrix",
          "type" => "movie",
          "startYear" => 1999,
          "primaryImage" => { "url" => "https://img.imdb.com/matrix.jpg" },
          "rating" => { "aggregateRating" => 8.7 }
        },
        {
          "id" => "tt10838180",
          "primaryTitle" => "The Matrix Resurrections",
          "type" => "movie",
          "startYear" => 2021,
          "primaryImage" => { "url" => "https://img.imdb.com/matrix4.jpg" },
          "rating" => { "aggregateRating" => 5.7 }
        }
      ]
    }.to_json

    @details_response = {
      "id" => "tt0133093",
      "primaryTitle" => "The Matrix",
      "type" => "movie",
      "startYear" => 1999,
      "plot" => "A computer hacker learns about the true nature of reality.",
      "genres" => [ "Action", "Sci-Fi" ],
      "directors" => [
        { "displayName" => "Lana Wachowski" },
        { "displayName" => "Lilly Wachowski" }
      ],
      "primaryImage" => { "url" => "https://img.imdb.com/matrix.jpg" },
      "rating" => { "aggregateRating" => 8.7 },
      "runtimeSeconds" => 8160
    }.to_json
  end

  test "search_titles returns mapped movie hashes" do
    stub_request(:get, /api\.imdbapi\.dev\/search\/titles/)
      .to_return(status: 200, body: @search_response, headers: { "Content-Type" => "application/json" })

    results = ImdbApiService.search_titles("the matrix")
    assert_equal 2, results.size

    movie = results.first
    assert_equal "movie", movie["_type"]
    assert_equal "tt0133093", movie["imdb_id"]
    assert_equal "The Matrix", movie["name"]
    assert_equal "1999", movie["year"]
    assert_equal 8.7, movie["rating"]
  end

  test "search_titles returns empty array on error" do
    stub_request(:get, /api\.imdbapi\.dev\/search\/titles/)
      .to_return(status: 500)

    assert_equal [], ImdbApiService.search_titles("anything")
  end

  test "title_details returns movie detail hash" do
    stub_request(:get, /api\.imdbapi\.dev\/titles\/tt0133093/)
      .to_return(status: 200, body: @details_response, headers: { "Content-Type" => "application/json" })

    result = ImdbApiService.title_details("tt0133093")
    assert_not_nil result
    assert_equal "tt0133093", result["imdb_id"]
    assert_equal "A computer hacker learns about the true nature of reality.", result["description"]
    assert_equal "Action, Sci-Fi", result["genres"]
    assert_equal "Lana Wachowski, Lilly Wachowski", result["director"]
    assert_equal 136, result["runtime"]
    assert_equal "1999", result["year"]
    assert_equal 8.7, result["rating"]
  end

  test "title_details returns nil on 404" do
    stub_request(:get, /api\.imdbapi\.dev\/titles\/tt9999999/)
      .to_return(status: 404)

    assert_nil ImdbApiService.title_details("tt9999999")
  end

  test "fetch_for_movie updates movie record" do
    stub_request(:get, /api\.imdbapi\.dev\/search\/titles/)
      .to_return(status: 200, body: @search_response, headers: { "Content-Type" => "application/json" })
    stub_request(:get, /api\.imdbapi\.dev\/titles\/tt0133093/)
      .to_return(status: 200, body: @details_response, headers: { "Content-Type" => "application/json" })

    movie = movies(:no_metadata_movie)
    movie.update_columns(title: "The Matrix") # so search matches

    result = ImdbApiService.fetch_for_movie(movie)
    assert result

    movie.reload
    assert_equal "tt0133093", movie.imdb_id
    assert_equal "https://img.imdb.com/matrix.jpg", movie.poster_url
    assert_includes movie.description, "computer hacker"
    assert_equal "Action, Sci-Fi", movie.genres
    assert_equal "Lana Wachowski, Lilly Wachowski", movie.director
    assert_equal 136, movie.runtime
  end

  test "fetch_for_movie returns false on search failure" do
    stub_request(:get, /api\.imdbapi\.dev\/search\/titles/)
      .to_return(status: 500)

    assert_not ImdbApiService.fetch_for_movie(movies(:no_metadata_movie))
  end

  test "handles rate limiting with retry" do
    stub_request(:get, /api\.imdbapi\.dev\/search\/titles/)
      .to_return(status: 429, headers: { "retry-after" => "0" })
      .then.to_return(status: 200, body: @search_response, headers: { "Content-Type" => "application/json" })

    results = ImdbApiService.search_titles("the matrix")
    assert_equal 2, results.size
  end
end
