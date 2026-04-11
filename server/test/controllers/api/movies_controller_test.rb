require "test_helper"

class Api::MoviesControllerTest < ActionDispatch::IntegrationTest
  test "index returns all movies" do
    get "/api/movies"
    assert_response :success

    data = JSON.parse(response.body)
    assert_kind_of Array, data
    assert data.size >= 3
    assert data.any? { |m| m["title"] == "The Matrix" }
  end

  test "show returns movie by slug with download" do
    get "/api/movies/the-matrix-1999"
    assert_response :success

    data = JSON.parse(response.body)
    assert_equal "The Matrix", data["title"]
    assert data.key?("download")
  end

  test "show returns 404 for unknown slug" do
    get "/api/movies/nonexistent"
    assert_response :not_found
  end

  test "create with file_paths creates movies" do
    stub_request(:get, /api\.imdbapi\.dev\/search\/titles/)
      .to_return(status: 404)

    post "/api/movies", params: { file_paths: [ "/media/Movies/New.Movie.2024.mkv" ] }, as: :json
    assert_response :created

    data = JSON.parse(response.body)
    assert_kind_of Array, data
  end

  test "create without file_paths returns 422" do
    post "/api/movies", params: {}, as: :json
    assert_response :unprocessable_entity
  end

  test "toggle switches watched status" do
    movie = movies(:inception)
    assert_not movie.watched?

    post "/api/movies/inception-2010/toggle"
    assert_response :success

    data = JSON.parse(response.body)
    assert_equal 1, data["watched"]

    # Toggle back
    post "/api/movies/inception-2010/toggle"
    assert_response :success

    data = JSON.parse(response.body)
    assert_equal 0, data["watched"]
  end

  test "refresh_metadata calls ImdbApiService" do
    stub_request(:get, /api\.imdbapi\.dev\/search\/titles/)
      .to_return(status: 404)

    post "/api/movies/the-matrix-1999/refresh_metadata"
    assert_response :success

    data = JSON.parse(response.body)
    assert data.key?("success")
  end

  test "destroy removes movie" do
    m = Movie.create!(title: "To Delete", file_path: "/tmp/del.mkv")
    delete "/api/movies/#{m.slug}"
    assert_response :no_content
    assert_nil Movie.find_by(slug: m.slug)
  end
end
