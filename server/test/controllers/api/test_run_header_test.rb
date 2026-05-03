require "test_helper"

class Api::TestRunHeaderTest < ActionDispatch::IntegrationTest
  setup do
    @episode = episodes(:bb_s01e01)
    @movie = movies(:the_matrix)
  end

  test "report_progress is short-circuited under X-Test-Run" do
    initial_progress = @episode.progress_seconds
    post "/api/playback/report_progress",
      params: { time: 999, duration: 1000, episode_id: @episode.id },
      headers: { "X-Test-Run" => "1" }
    assert_response :success
    assert_equal initial_progress, @episode.reload.progress_seconds
    body = JSON.parse(response.body)
    assert_equal true, body["testMode"]
  end

  test "episode play creates no WatchHistory under X-Test-Run" do
    initial_watched = @episode.watched
    assert_no_difference -> { WatchHistory.count } do
      post "/api/episodes/#{@episode.id}/play", headers: { "X-Test-Run" => "1" }
    end
    # Status may be 422 if the fixture's file_path doesn't exist on disk;
    # the property under test is "no DB write happened".
    assert_equal initial_watched, @episode.reload.watched
  end

  test "episode toggle is short-circuited under X-Test-Run" do
    initial = @episode.watched
    post "/api/episodes/#{@episode.id}/toggle", headers: { "X-Test-Run" => "1" }
    assert_equal initial, @episode.reload.watched
    assert_response :success
  end

  test "movie play does not mark watched under X-Test-Run" do
    initial_watched = @movie.watched
    initial_progress = @movie.progress_seconds
    post "/api/movies/#{@movie.slug}/play", headers: { "X-Test-Run" => "1" }
    # Status may be 422 if the fixture's file_path doesn't exist on disk;
    # the property under test is "no DB write happened".
    assert_equal initial_watched, @movie.reload.watched
    assert_equal initial_progress, @movie.progress_seconds
  end

  test "movie toggle is short-circuited under X-Test-Run" do
    initial = @movie.watched
    post "/api/movies/#{@movie.slug}/toggle", headers: { "X-Test-Run" => "1" }
    assert_equal initial, @movie.reload.watched
    assert_response :success
  end

  test "report_progress writes normally without X-Test-Run" do
    post "/api/playback/report_progress",
      params: { time: 250, duration: 1000, episode_id: @episode.id }
    assert_response :success
    assert_equal 250, @episode.reload.progress_seconds
  end
end
