require "test_helper"

class WatchHistoryTest < ActiveSupport::TestCase
  test "fixtures load" do
    wh = watch_histories(:history_one)
    assert_equal episodes(:bb_s01e01), wh.episode
    assert_equal 3480, wh.progress_seconds
  end

  test "belongs to episode" do
    wh = watch_histories(:history_one)
    assert_equal "S01E01", wh.episode.code
  end

  test "has_one series through episode" do
    wh = watch_histories(:history_one)
    assert_equal series(:breaking_bad), wh.series
  end

  test "update_progress! sets fields and ended_at" do
    wh = watch_histories(:history_two)
    wh.update_progress!(2000, 2880)
    assert_equal 2000, wh.progress_seconds
    assert_equal 2880, wh.duration_seconds
    assert_not_nil wh.ended_at
  end
end
