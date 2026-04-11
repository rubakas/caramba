require "test_helper"

class Api::MediaControllerTest < ActionDispatch::IntegrationTest
  test "episode streaming returns file when it exists" do
    ep = episodes(:bb_s01e01)

    # Create a temp file to stream
    Tempfile.create([ "test_episode", ".mkv" ]) do |f|
      f.write("fake mkv data")
      f.flush
      ep.update_columns(file_path: f.path)

      get "/api/media/episodes/#{ep.id}"
      assert_response :success
      assert_equal "video/x-matroska", response.media_type
    end
  end

  test "episode streaming returns 404 when file missing" do
    ep = episodes(:bb_s02e01)
    ep.update_columns(file_path: "/nonexistent/file.mkv")

    get "/api/media/episodes/#{ep.id}"
    assert_response :not_found
  end

  test "episode streaming returns 404 when file_path nil" do
    ep = episodes(:bb_s02e01)
    ep.update_columns(file_path: nil)

    get "/api/media/episodes/#{ep.id}"
    assert_response :not_found
  end

  test "movie streaming returns file when it exists" do
    movie = movies(:the_matrix)

    Tempfile.create([ "test_movie", ".mp4" ]) do |f|
      f.write("fake mp4 data")
      f.flush
      movie.update_columns(file_path: f.path)

      get "/api/media/movies/#{movie.id}"
      assert_response :success
      assert_equal "video/mp4", response.media_type
    end
  end

  test "movie streaming returns 404 when file missing" do
    movie = movies(:inception)
    movie.update_columns(file_path: "/nonexistent/movie.mkv")

    get "/api/media/movies/#{movie.id}"
    assert_response :not_found
  end

  test "episode returns 404 for unknown id" do
    get "/api/media/episodes/999999"
    assert_response :not_found
  end

  test "movie returns 404 for unknown id" do
    get "/api/media/movies/999999"
    assert_response :not_found
  end
end
