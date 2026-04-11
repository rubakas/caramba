require "test_helper"

class MovieTest < ActiveSupport::TestCase
  test "fixtures load" do
    m = movies(:the_matrix)
    assert_equal "The Matrix", m.title
    assert_equal "the-matrix-1999", m.slug
  end

  test "validates title presence" do
    m = Movie.new(title: nil)
    assert_not m.valid?
    assert_includes m.errors[:title], "can't be blank"
  end

  test "generates slug with year on create" do
    m = Movie.create!(title: "Dune", year: "2021", file_path: "/media/dune.mkv")
    assert_equal "dune-2021", m.slug
  end

  test "generates slug without year when nil" do
    m = Movie.create!(title: "Akira", file_path: "/media/akira.mkv")
    assert_equal "akira", m.slug
  end

  test "unique slug on collision" do
    Movie.create!(title: "The Matrix", year: "1999", file_path: "/media/matrix2.mkv")
    m2 = Movie.create!(title: "The Matrix", year: "1999", file_path: "/media/matrix3.mkv")
    assert_match(/\Athe-matrix-1999-\d+\z/, m2.slug)
  end

  test "file_path uniqueness" do
    m = Movie.new(title: "Dup", file_path: movies(:the_matrix).file_path)
    assert_not m.valid?
    assert_includes m.errors[:file_path], "has already been taken"
  end

  test "watched? returns boolean" do
    assert movies(:the_matrix).watched?
    assert_not movies(:inception).watched?
  end

  test "mark_watched!" do
    m = movies(:inception)
    m.mark_watched!
    assert m.watched?
    assert_not_nil m.last_watched_at
  end

  test "mark_unwatched!" do
    m = movies(:the_matrix)
    m.mark_unwatched!
    assert_not m.watched?
    assert_equal 0, m.progress_seconds
    assert_nil m.last_watched_at
  end

  test "update_progress!" do
    m = movies(:inception)
    m.update_progress!(3000, 8880)
    assert_equal 3000, m.progress_seconds
    assert_equal 8880, m.duration_seconds
    assert_not_nil m.last_watched_at
  end
end
