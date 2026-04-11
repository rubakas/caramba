require "test_helper"

class MediaScannerServiceTest < ActiveSupport::TestCase
  test "name_from_path strips parenthesized year" do
    assert_equal "Black Books", MediaScannerService.name_from_path("/media/Black Books (2000) Season 1-3")
  end

  test "name_from_path strips dot-separated year" do
    assert_equal "The Simpsons", MediaScannerService.name_from_path("/media/The.Simpsons.1989.Complete")
  end

  test "name_from_path strips season code" do
    assert_equal "The City And The City", MediaScannerService.name_from_path("/media/The.City.And.The.City.S01.1080p")
  end

  test "name_from_path replaces dots with spaces" do
    assert_equal "Some Show", MediaScannerService.name_from_path("/media/Some.Show")
  end

  test "parse_episode extracts season, episode, title from dot-separated" do
    result = MediaScannerService.parse_episode("Breaking.Bad.S01E02.Cats.in.the.Bag.1080p.BluRay.mkv")
    assert_equal 1, result[:season]
    assert_equal 2, result[:episode]
    assert_equal "S01E02", result[:code]
    assert_equal "Cats in the Bag", result[:title]
  end

  test "parse_episode extracts from hyphen-separated" do
    result = MediaScannerService.parse_episode("The Office S03E14 - The Return (1080p).mkv")
    assert_equal 3, result[:season]
    assert_equal 14, result[:episode]
    assert_equal "S03E14", result[:code]
    assert_equal "The Return", result[:title]
  end

  test "parse_episode uses code as title when no title found" do
    result = MediaScannerService.parse_episode("S01E01.1080p.mkv")
    assert_equal "S01E01", result[:title]
  end

  test "parse_episode returns nil for non-episode filename" do
    assert_nil MediaScannerService.parse_episode("random_movie_file.mkv")
  end

  test "parse_episode handles lowercase codes" do
    result = MediaScannerService.parse_episode("show.s02e05.title.mkv")
    assert_equal 2, result[:season]
    assert_equal 5, result[:episode]
    assert_equal "S02E05", result[:code]
  end

  test "scan creates episodes from filesystem" do
    s = series(:no_metadata)

    # Create a temp dir structure
    Dir.mktmpdir do |dir|
      s.update!(media_path: dir)

      season_dir = File.join(dir, "Season 1")
      FileUtils.mkdir_p(season_dir)
      FileUtils.touch(File.join(season_dir, "Show.S01E01.Pilot.1080p.mkv"))
      FileUtils.touch(File.join(season_dir, "Show.S01E02.Second.Episode.mkv"))
      FileUtils.touch(File.join(season_dir, "nfo_file.nfo")) # should be ignored

      count = MediaScannerService.scan(s)
      assert_equal 2, count
      assert_equal 2, s.episodes.count
      assert_equal "S01E01", s.episodes.order(:episode_number).first.code
    end
  end

  test "scan handles flat structure" do
    s = series(:no_metadata)

    Dir.mktmpdir do |dir|
      s.update!(media_path: dir)
      FileUtils.touch(File.join(dir, "Show.S01E01.Pilot.mkv"))
      FileUtils.touch(File.join(dir, "Show.S01E02.Second.mkv"))

      count = MediaScannerService.scan(s)
      assert_equal 2, count
    end
  end

  test "scan returns 0 when media_path missing" do
    s = series(:no_metadata)
    s.update_columns(media_path: "/nonexistent/path")
    assert_equal 0, MediaScannerService.scan(s)
  end

  test "scan upserts existing episodes" do
    s = series(:no_metadata)

    Dir.mktmpdir do |dir|
      s.update!(media_path: dir)
      FileUtils.touch(File.join(dir, "Show.S01E01.Original.mkv"))

      MediaScannerService.scan(s)
      assert_equal 1, s.episodes.count
      ep = s.episodes.first
      assert_equal "Original", ep.title

      # Scan again — same code, should update not duplicate
      File.delete(File.join(dir, "Show.S01E01.Original.mkv"))
      FileUtils.touch(File.join(dir, "Show.S01E01.Updated.Title.mkv"))

      MediaScannerService.scan(s)
      assert_equal 1, s.episodes.count
      assert_equal "Updated Title", s.episodes.first.title
    end
  end

  test "collect_mkv_files handles release folder nesting" do
    Dir.mktmpdir do |dir|
      # No season dirs at root — but a release folder one level deep
      release_dir = File.join(dir, "Show.Complete.Pack")
      season_dir = File.join(release_dir, "Season 1")
      FileUtils.mkdir_p(season_dir)
      FileUtils.touch(File.join(season_dir, "S01E01.mkv"))

      files = MediaScannerService.collect_mkv_files(dir)
      assert_equal 1, files.size
      assert files.first[1].end_with?("S01E01.mkv")
    end
  end
end
