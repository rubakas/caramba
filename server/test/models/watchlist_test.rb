require "test_helper"

class WatchlistTest < ActiveSupport::TestCase
  test "fixtures load" do
    show = watchlist(:watchlist_show)
    assert_equal "Better Call Saul", show.name
    assert_equal "show", show.type

    movie = watchlist(:watchlist_movie)
    assert_equal "Interstellar", movie.name
    assert_equal "movie", movie.type
  end

  test "table name is watchlist" do
    assert_equal "watchlist", Watchlist.table_name
  end

  test "validates name presence" do
    w = Watchlist.new(type: "show")
    assert_not w.valid?
    assert_includes w.errors[:name], "can't be blank"
  end

  test "validates type presence and inclusion" do
    w = Watchlist.new(name: "Foo", type: nil)
    assert_not w.valid?
    assert_includes w.errors[:type], "can't be blank"

    w.type = "invalid"
    assert_not w.valid?
    assert_includes w.errors[:type], "is not included in the list"
  end

  test "tvmaze_id uniqueness" do
    w = Watchlist.new(name: "Dup", type: "show", tvmaze_id: watchlist(:watchlist_show).tvmaze_id)
    assert_not w.valid?
    assert_includes w.errors[:tvmaze_id], "has already been taken"
  end

  test "imdb_id uniqueness" do
    w = Watchlist.new(name: "Dup", type: "movie", imdb_id: watchlist(:watchlist_movie).imdb_id)
    assert_not w.valid?
    assert_includes w.errors[:imdb_id], "has already been taken"
  end

  test "scopes" do
    assert_includes Watchlist.shows, watchlist(:watchlist_show)
    assert_includes Watchlist.movies, watchlist(:watchlist_movie)
    assert_not_includes Watchlist.shows, watchlist(:watchlist_movie)
  end
end
