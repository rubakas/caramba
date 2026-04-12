require "test_helper"

class Api::HistoryControllerTest < ActionDispatch::IntegrationTest
  test "index returns watch histories with episode and series data" do
    get "/api/history"
    assert_response :success

    data = JSON.parse(response.body)
    assert_kind_of Array, data
    assert data.size >= 2

    first = data.first
    assert first.key?("code")
    assert first.key?("episode_title")
    assert first.key?("series_name")
    assert first.key?("series_slug")
  end

  test "index respects limit param" do
    get "/api/history", params: { limit: 1 }
    assert_response :success

    data = JSON.parse(response.body)
    assert_equal 1, data.size
  end

  test "stats returns aggregated data" do
    get "/api/history/stats"
    assert_response :success

    data = JSON.parse(response.body)
    assert data.key?("total_time")
    assert data.key?("total_episodes")
    assert data.key?("total_series")
    assert data["total_time"] > 0
    assert data["total_episodes"] > 0
  end
end
