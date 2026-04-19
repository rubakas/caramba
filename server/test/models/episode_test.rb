require "test_helper"

class EpisodeTest < ActiveSupport::TestCase
  test "fixtures load" do
    ep = episodes(:bb_s01e01)
    assert_equal "S01E01", ep.code
    assert_equal "Pilot", ep.title
    assert_equal 1, ep.season_number
    assert_equal 1, ep.episode_number
  end

  test "belongs to show" do
    ep = episodes(:bb_s01e01)
    assert_equal shows(:breaking_bad), ep.show
  end

  test "validates code presence" do
    ep = Episode.new(show: shows(:breaking_bad), code: nil)
    assert_not ep.valid?
    assert_includes ep.errors[:code], "can't be blank"
  end

  test "validates code uniqueness scoped to show" do
    ep = Episode.new(show: shows(:breaking_bad), code: "S01E01")
    assert_not ep.valid?
    assert_includes ep.errors[:code], "has already been taken"
  end

  test "same code allowed on different shows" do
    ep = Episode.new(show: shows(:the_office), code: "S01E02", title: "Diversity Day")
    assert ep.valid?
  end

  test "watched? returns boolean" do
    assert episodes(:bb_s01e01).watched?
    assert_not episodes(:bb_s01e02).watched?
  end

  test "mark_watched! sets watched and timestamp" do
    ep = episodes(:bb_s01e02)
    ep.mark_watched!
    assert ep.watched?
    assert_not_nil ep.last_watched_at
  end

  test "mark_unwatched! resets watched and progress" do
    ep = episodes(:bb_s01e01)
    ep.mark_unwatched!
    assert_not ep.watched?
    assert_equal 0, ep.progress_seconds
    assert_nil ep.last_watched_at
  end

  test "update_progress! sets progress and duration" do
    ep = episodes(:bb_s02e01)
    ep.update_progress!(500, 3000)
    assert_equal 500, ep.progress_seconds
    assert_equal 3000, ep.duration_seconds
    assert_not_nil ep.last_watched_at
  end

  test "next_episode returns next in show order" do
    ep = episodes(:bb_s01e01)
    nxt = ep.next_episode
    assert_equal episodes(:bb_s01e02), nxt
  end

  test "next_episode crosses season boundary" do
    ep = episodes(:bb_s01e02)
    nxt = ep.next_episode
    assert_equal episodes(:bb_s02e01), nxt
  end

  test "next_episode returns nil for last episode" do
    ep = episodes(:bb_s02e01)
    assert_nil ep.next_episode
  end

  test "scopes work" do
    bb = shows(:breaking_bad)
    assert_equal 1, bb.episodes.watched.count
    assert_equal 2, bb.episodes.unwatched.count
    assert_equal [ 1, 1, 2 ], bb.episodes.ordered.pluck(:season_number, :episode_number).map(&:first)
  end
end
