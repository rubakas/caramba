require "test_helper"

class FilenameParserServiceTest < ActiveSupport::TestCase
  # ── Movies ─────────────────────────────────────────────────────────

  test "parses movie with dot-separated year + quality noise" do
    r = FilenameParserService.parse("The.Matrix.1999.1080p.BluRay.x264-AMIABLE.mkv")
    assert_equal :movie, r[:type]
    assert_equal "The Matrix", r[:title]
    assert_equal 1999, r[:year]
  end

  test "parses movie with parenthesized year and trailing tag" do
    r = FilenameParserService.parse("Dune Part Two (2024) [1080p].mkv")
    assert_equal :movie, r[:type]
    assert_equal "Dune Part Two", r[:title]
    assert_equal 2024, r[:year]
  end

  test "extracts imdb id from filename marker" do
    r = FilenameParserService.parse("Movie (2020) [imdbid-tt1234567].mkv")
    assert_equal "tt1234567", r[:provider_ids][:imdb]
  end

  test "extracts loose imdb id anywhere in path" do
    r = FilenameParserService.parse("/library/My Show tt9876543/Episode 1.mkv")
    assert_equal "tt9876543", r[:provider_ids][:imdb]
  end

  test "extracts tmdb id from bracket marker" do
    r = FilenameParserService.parse("Show [tmdbid-12345].mkv")
    assert_equal "12345", r[:provider_ids][:tmdb]
  end

  # ── Episodes ───────────────────────────────────────────────────────

  test "parses S##E## standard form" do
    r = FilenameParserService.parse("Breaking.Bad.S03E07.One.Minute.720p.BluRay.x264-REWARD.mkv")
    assert_equal :episode, r[:type]
    assert_equal 3, r[:season]
    assert_equal 7, r[:episode]
  end

  test "parses 1x05 form" do
    r = FilenameParserService.parse("My.Show.1x05.Title.mkv")
    assert_equal :episode, r[:type]
    assert_equal 1, r[:season]
    assert_equal 5, r[:episode]
  end

  test "parses Season X Episode Y form" do
    r = FilenameParserService.parse("Show Season 02 Episode 15.mkv")
    assert_equal :episode, r[:type]
    assert_equal 2, r[:season]
    assert_equal 15, r[:episode]
  end

  test "parses bare Episode form (assumes season 1)" do
    r = FilenameParserService.parse("Episode 16 - Pilot.mkv")
    assert_equal :episode, r[:type]
    assert_equal 1, r[:season]
    assert_equal 16, r[:episode]
  end

  test "parses multi-episode S##E##-E##" do
    r = FilenameParserService.parse("Show.S01E01-E03.Title.mkv")
    assert_equal :episode, r[:type]
    assert_equal 1, r[:season]
    assert_equal 1, r[:episode]
    assert_equal 3, r[:episode_end]
  end

  test "parses date-based episode (talk show)" do
    r = FilenameParserService.parse("Talk.Show.2024.04.20.Guest.mkv")
    assert_equal :episode, r[:type]
    assert_equal "2024-04-20", r[:air_date]
  end

  # ── Defensive guards ───────────────────────────────────────────────

  test "rejects bogus season number from resolution-looking filename" do
    r = FilenameParserService.parse("Movie (1920x1080).mkv")
    assert_equal :movie, r[:type], "Expected (1920x1080) NOT to be parsed as S1920E1080"
  end

  test "trailing-digit guard does not eat resolution as episode_end" do
    r = FilenameParserService.parse("Show.S09E14-1080p.mkv")
    assert_equal :episode, r[:type]
    assert_equal 9, r[:season]
    assert_equal 14, r[:episode]
    assert_nil r[:episode_end], "1080p should not become episode_end"
  end

  # ── Extras ─────────────────────────────────────────────────────────

  test "detects bare trailer filename" do
    assert_equal :trailer, FilenameParserService.parse("trailer.mkv")[:is_extra]
  end

  test "detects -sample suffix" do
    assert_equal :sample, FilenameParserService.parse("Movie-sample.mkv")[:is_extra]
  end

  test "detects extras from parent directory name" do
    r = FilenameParserService.parse("/library/Some Show/behind the scenes/clip.mkv")
    assert_equal :behindthescenes, r[:is_extra]
  end

  # ── Season folders ─────────────────────────────────────────────────

  test "season_from_folder recognizes English/French/Russian/numeric" do
    assert_equal 1, FilenameParserService.season_from_folder("Season 1")
    assert_equal 12, FilenameParserService.season_from_folder("Season 12")
    assert_equal 3, FilenameParserService.season_from_folder("Saison 3")
    assert_equal 4, FilenameParserService.season_from_folder("Сезон 4")
    assert_equal 0, FilenameParserService.season_from_folder("specials")
    assert_equal 0, FilenameParserService.season_from_folder("Extras")
    assert_equal 1, FilenameParserService.season_from_folder("S01")
    assert_nil FilenameParserService.season_from_folder("random")
  end

  # ── Video file detection ───────────────────────────────────────────

  test "video_file recognizes common extensions" do
    %w[a.mkv a.mp4 a.avi a.mov a.m4v a.ts a.m2ts a.webm].each do |f|
      assert FilenameParserService.video_file?(f), "expected #{f} to be a video file"
    end
    %w[a.nfo a.srt a.txt a.iso].each do |f|
      assert_not FilenameParserService.video_file?(f), "expected #{f} NOT to be a video file"
    end
  end
end
