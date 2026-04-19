require "test_helper"

class Api::EpisodesControllerTest < ActionDispatch::IntegrationTest
  test "toggle marks unwatched episode as watched" do
    ep = episodes(:bb_s01e02)
    assert_not ep.watched?

    post "/api/episodes/#{ep.id}/toggle"
    assert_response :success

    data = JSON.parse(response.body)
    assert_equal 1, data["watched"]
  end

  test "toggle marks watched episode as unwatched" do
    ep = episodes(:bb_s01e01)
    assert ep.watched?

    post "/api/episodes/#{ep.id}/toggle"
    assert_response :success

    data = JSON.parse(response.body)
    assert_equal 0, data["watched"]
  end

  test "toggle returns 404 for unknown episode" do
    post "/api/episodes/999999/toggle"
    assert_response :not_found
  end

  test "next returns next episode with show_name" do
    ep = episodes(:bb_s01e01)

    get "/api/episodes/#{ep.id}/next"
    assert_response :success

    data = JSON.parse(response.body)
    assert_equal "S01E02", data["code"]
    assert_equal "Breaking Bad", data["show_name"]
  end

  test "next returns null for last episode" do
    ep = episodes(:bb_s02e01)

    get "/api/episodes/#{ep.id}/next"
    assert_response :success

    assert_equal "null", response.body.strip
  end
end
