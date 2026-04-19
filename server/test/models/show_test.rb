require "test_helper"

class ShowTest < ActiveSupport::TestCase
  test "fixtures load" do
    assert_equal "Breaking Bad", shows(:breaking_bad).name
    assert_equal "the-office", shows(:the_office).slug
  end

  test "validates name presence" do
    s = Show.new(name: nil)
    assert_not s.valid?
    assert_includes s.errors[:name], "can't be blank"
  end

  test "generates slug on create" do
    s = Show.create!(name: "The Wire", media_path: "/media/the-wire")
    assert_equal "the-wire", s.slug
  end

  test "generates unique slug when collision" do
    Show.create!(name: "Breaking Bad", media_path: "/media/bb2")
    s2 = Show.create!(name: "Breaking Bad", media_path: "/media/bb3")
    assert_match(/\Abreaking-bad-\d+\z/, s2.slug)
  end

  test "slug uniqueness validated" do
    s = Show.new(name: "Foo", slug: "breaking-bad")
    assert_not s.valid?
    assert_includes s.errors[:slug], "has already been taken"
  end

  test "season_count returns distinct season numbers" do
    assert_equal 2, shows(:breaking_bad).season_count
  end

  test "total_watch_time sums watch_histories" do
    bb = shows(:breaking_bad)
    assert bb.total_watch_time >= 0
  end

  test "has_many episodes" do
    bb = shows(:breaking_bad)
    assert_equal 3, bb.episodes.count
  end

  test "destroying show cascades to episodes" do
    bb = shows(:breaking_bad)
    ep_count = bb.episodes.count
    assert ep_count > 0
    bb.destroy!
    assert_equal 0, Episode.where(show_id: bb.id).count
  end
end
