require "test_helper"

class NfoParserServiceTest < ActiveSupport::TestCase
  test "parses tvshow.nfo with imdbid + uniqueid + plot" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "tvshow.nfo"), <<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <tvshow>
          <title>The Wire</title>
          <plot>Baltimore drug trade.</plot>
          <year>2002</year>
          <premiered>2002-06-02</premiered>
          <runtime>60</runtime>
          <rating>9.3</rating>
          <imdbid>tt0306414</imdbid>
          <uniqueid type="tvdb">79126</uniqueid>
          <genre>Drama</genre>
          <genre>Crime</genre>
        </tvshow>
        https://www.themoviedb.org/tv/1438
      XML

      attrs = NfoParserService.read_show(dir)
      assert attrs.is_a?(Hash)
      assert_equal "The Wire", attrs[:title]
      assert_equal "Baltimore drug trade.", attrs[:description]
      assert_equal "2002", attrs[:year]
      assert_equal 60, attrs[:runtime]
      assert_in_delta 9.3, attrs[:rating], 0.001
      assert_equal "Drama, Crime", attrs[:genres]
      assert_equal "tt0306414", attrs[:imdb_id]
      assert_equal "79126", attrs[:provider_ids][:tvdb]
    end
  end

  test "parses movie.nfo with uniqueid type=imdb" do
    Dir.mktmpdir do |dir|
      file = File.join(dir, "Inception (2010).mkv")
      FileUtils.touch(file)
      File.write(File.join(dir, "Inception (2010).nfo"), <<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <movie>
          <title>Inception</title>
          <plot>A thief who steals corporate secrets through dream-sharing.</plot>
          <year>2010</year>
          <uniqueid type="imdb">tt1375666</uniqueid>
          <director>Christopher Nolan</director>
        </movie>
      XML

      attrs = NfoParserService.read_movie(file)
      assert_equal "Inception", attrs[:title]
      assert_equal "tt1375666", attrs[:imdb_id]
      assert_equal "Christopher Nolan", attrs[:director]
      assert_equal "2010", attrs[:year]
    end
  end

  test "returns nil when no nfo file exists" do
    Dir.mktmpdir do |dir|
      assert_nil NfoParserService.read_show(dir)
      assert_nil NfoParserService.read_movie(File.join(dir, "nope.mkv"))
    end
  end

  test "handles trailing junk after closing tag (Kodi quirk)" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "tvshow.nfo"), <<~XML)
        <tvshow><title>Show</title><imdbid>tt0000001</imdbid></tvshow>some-trailing-stuff-here
      XML
      attrs = NfoParserService.read_show(dir)
      assert_equal "Show", attrs[:title]
      assert_equal "tt0000001", attrs[:imdb_id]
    end
  end
end
