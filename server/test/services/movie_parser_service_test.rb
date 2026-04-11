require "test_helper"

class MovieParserServiceTest < ActiveSupport::TestCase
  test "name_from_filename strips parenthesized year" do
    assert_equal "The Matrix", MovieParserService.name_from_filename("The Matrix (1999).mkv")
    assert_equal "The Matrix", MovieParserService.name_from_filename("/movies/The Matrix (1999) 1080p.mkv")
  end

  test "name_from_filename strips dot-separated year" do
    assert_equal "The Matrix", MovieParserService.name_from_filename("The.Matrix.1999.1080p.BluRay.mkv")
  end

  test "name_from_filename strips quality markers" do
    assert_equal "Some Movie", MovieParserService.name_from_filename("Some.Movie.1080p.WEB-DL.mkv")
  end

  test "name_from_filename handles clean name" do
    assert_equal "Simple", MovieParserService.name_from_filename("Simple.mkv")
  end

  test "year_from_filename extracts parenthesized year" do
    assert_equal "1999", MovieParserService.year_from_filename("The Matrix (1999).mkv")
  end

  test "year_from_filename extracts dot-separated year" do
    assert_equal "1999", MovieParserService.year_from_filename("The.Matrix.1999.1080p.mkv")
  end

  test "year_from_filename returns nil when no year" do
    assert_nil MovieParserService.year_from_filename("Simple.mkv")
  end

  test "year_from_filename prefers parenthesized" do
    assert_equal "2001", MovieParserService.year_from_filename("Film (2001) 2020 Remaster.mkv")
  end
end
