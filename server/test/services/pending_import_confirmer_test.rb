require "test_helper"

class PendingImportConfirmerTest < ActiveSupport::TestCase
  setup do
    @root = Dir.mktmpdir
    @folder = MediaFolder.create!(path: @root, kind: "series")

    stub_request(:get, %r{api\.tvmaze\.com/shows/169}).to_return(
      status: 200,
      body: {
        id: 169,
        name: "Breaking Bad",
        image: { original: "https://example.com/bb.jpg" },
        summary: "<p>A high school chemistry teacher...</p>",
        genres: [ "Drama" ],
        rating: { average: 9.5 },
        premiered: "2008-01-20",
        status: "Ended",
        externals: { imdb: "tt0903747" },
        _embedded: { episodes: [] }
      }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    stub_request(:get, %r{api\.imdbapi\.dev/titles/tt1375666}).to_return(
      status: 200,
      body: {
        id: "tt1375666",
        plot: "A thief enters dreams...",
        genres: [ "Action", "Sci-Fi" ],
        directors: [ { displayName: "Christopher Nolan" } ],
        runtimeSeconds: 8880,
        startYear: 2010,
        rating: { aggregateRating: 8.8 },
        primaryImage: { url: "https://example.com/inception.jpg" }
      }.to_json,
      headers: { "Content-Type" => "application/json" }
    )
  end

  teardown do
    FileUtils.remove_entry(@root) if @root
  end

  test "confirm series creates Series and marks pending_import confirmed" do
    show_dir = File.join(@root, "Breaking Bad (2008)")
    Dir.mkdir(show_dir)
    pi = PendingImport.create!(
      media_folder: @folder,
      folder_path: show_dir,
      kind: "series",
      parsed_name: "Breaking Bad",
      candidates: [ { "externalId" => 169, "name" => "Breaking Bad", "source" => "tvmaze" } ]
    )

    series = PendingImportConfirmer.confirm(pi, 169)

    assert series.is_a?(Series)
    assert_equal "Breaking Bad", series.name
    assert_equal show_dir, series.media_path
    assert_equal 169, series.tvmaze_id
    assert_equal "tt0903747", series.imdb_id

    pi.reload
    assert_equal "confirmed", pi.status
    assert_equal "169", pi.chosen_external_id
  end

  test "confirm movies creates Movie and marks pending_import confirmed" do
    movies_root = Dir.mktmpdir
    movies_folder = MediaFolder.create!(path: movies_root, kind: "movies")
    movie_path = File.join(movies_root, "Inception (2010).mkv")
    File.write(movie_path, "")

    pi = PendingImport.create!(
      media_folder: movies_folder,
      folder_path: movie_path,
      kind: "movies",
      parsed_name: "Inception",
      parsed_year: 2010,
      candidates: [ { "externalId" => "tt1375666", "name" => "Inception", "source" => "imdb", "year" => 2010 } ]
    )

    movie = PendingImportConfirmer.confirm(pi, "tt1375666")

    assert movie.is_a?(Movie)
    assert_equal "Inception", movie.title
    assert_equal movie_path, movie.file_path
    assert_equal "tt1375666", movie.imdb_id
    assert_equal "2010", movie.year

    pi.reload
    assert_equal "confirmed", pi.status
    assert_equal "tt1375666", pi.chosen_external_id
  ensure
    FileUtils.remove_entry(movies_root) if movies_root
  end

  test "confirm series scans episodes from the folder" do
    show_dir = File.join(@root, "Breaking Bad (2008)")
    Dir.mkdir(show_dir)
    File.write(File.join(show_dir, "Breaking.Bad.S01E01.mkv"), "")
    File.write(File.join(show_dir, "Breaking.Bad.S01E02.mkv"), "")

    pi = PendingImport.create!(
      media_folder: @folder,
      folder_path: show_dir,
      kind: "series",
      parsed_name: "Breaking Bad",
      candidates: [ { "externalId" => 169 } ]
    )

    series = PendingImportConfirmer.confirm(pi, 169)
    assert_equal 2, series.episodes.count
  end

  test "confirm raises on blank external_id" do
    pi = PendingImport.create!(
      media_folder: @folder,
      folder_path: File.join(@root, "Something"),
      kind: "series"
    )
    assert_raises(ArgumentError) { PendingImportConfirmer.confirm(pi, "") }
    # status stays pending — blank id is a user-input error caught before
    # any persistence work, so we don't flip the import into a failed state.
    assert_equal "pending", pi.reload.status
  end

  test "confirm marks pending_import failed when record save raises" do
    show_dir = File.join(@root, "Breaking Bad")
    Dir.mkdir(show_dir)
    pi = PendingImport.create!(
      media_folder: @folder,
      folder_path: show_dir,
      kind: "series",
      parsed_name: "Breaking Bad",
      candidates: [ { "externalId" => 169, "name" => "Breaking Bad" } ]
    )

    # Any Series created with this path would succeed. Force failure by
    # creating one first — uniqueness on media_path isn't enforced, so we
    # instead rely on slug uniqueness by pre-seeding the expected slug and
    # saturating the -1..-N counters beyond reach (the generator appends
    # -#{counter}).
    # Simpler: stub Series.new to raise.
    fake_series = Series.new(name: "x")
    fake_series.errors.add(:base, "forced failure")

    original = Series.method(:new)
    Series.define_singleton_method(:new) { |*_args| raise ActiveRecord::RecordInvalid.new(fake_series) }

    begin
      assert_raises(ActiveRecord::RecordInvalid) { PendingImportConfirmer.confirm(pi, 169) }
    ensure
      Series.define_singleton_method(:new, original)
    end

    pi.reload
    assert_equal "failed", pi.status
    assert pi.error.present?
  end
end
