require "test_helper"

class LibraryWatcherServiceTest < ActiveSupport::TestCase
  setup do
    @root = Dir.mktmpdir
    @shows_folder = MediaFolder.create!(path: @root, kind: "shows")
  end

  teardown do
    FileUtils.remove_entry(@root) if @root
  end

  test "creates PendingImport for each unknown top-level directory" do
    Dir.mkdir(File.join(@root, "Breaking Bad (2008)"))
    Dir.mkdir(File.join(@root, "The.Office.S01"))
    stub_tvmaze_empty

    created = LibraryWatcherService.scan_folder(@shows_folder)
    assert_equal 2, created
    paths = PendingImport.pluck(:folder_path)
    assert_includes paths, File.join(@root, "Breaking Bad (2008)")
    assert_includes paths, File.join(@root, "The.Office.S01")
  end

  test "cleans parsed_name using MediaScannerService" do
    Dir.mkdir(File.join(@root, "Breaking Bad (2008) Complete"))
    stub_tvmaze_empty

    LibraryWatcherService.scan_folder(@shows_folder)
    pi = PendingImport.find_by(folder_path: File.join(@root, "Breaking Bad (2008) Complete"))
    assert_equal "Breaking Bad", pi.parsed_name
  end

  test "stores top 5 candidates from TVMaze search" do
    Dir.mkdir(File.join(@root, "Breaking Bad"))
    stub_tvmaze_search("Breaking Bad", build_tvmaze_results(7))

    LibraryWatcherService.scan_folder(@shows_folder)
    pi = PendingImport.find_by(folder_path: File.join(@root, "Breaking Bad"))
    assert_equal 5, pi.candidates.size
    first = pi.candidates.first
    assert_equal 1, first["externalId"]
    assert_equal "tvmaze", first["source"]
  end

  test "skips existing Show with same media_path" do
    show_path = File.join(@root, "Existing Show")
    Dir.mkdir(show_path)
    Show.create!(name: "Existing Show", media_path: show_path)
    stub_tvmaze_empty

    LibraryWatcherService.scan_folder(@shows_folder)
    assert_equal 0, PendingImport.where(folder_path: show_path).count
  end

  test "skips existing PendingImport with same folder_path" do
    show_path = File.join(@root, "Already Pending")
    Dir.mkdir(show_path)
    PendingImport.create!(media_folder: @shows_folder, folder_path: show_path, kind: "shows")
    stub_tvmaze_empty

    # Also create a second show to ensure scan is active but the existing entry is skipped
    Dir.mkdir(File.join(@root, "Another Show"))
    LibraryWatcherService.scan_folder(@shows_folder)
    assert_equal 1, PendingImport.where(folder_path: show_path).count
  end

  test "caps at NEW_IMPORTS_PER_RUN" do
    (LibraryWatcherService::NEW_IMPORTS_PER_RUN + 5).times do |i|
      Dir.mkdir(File.join(@root, "Show #{i}"))
    end
    stub_tvmaze_empty

    created = LibraryWatcherService.scan_folder(@shows_folder)
    assert_equal LibraryWatcherService::NEW_IMPORTS_PER_RUN, created
  end

  test "updates last_scanned_at" do
    @shows_folder.update!(last_scanned_at: nil)
    stub_tvmaze_empty

    LibraryWatcherService.scan_folder(@shows_folder)
    assert_not_nil @shows_folder.reload.last_scanned_at
  end

  test "ignores files and dotfiles under shows root" do
    Dir.mkdir(File.join(@root, ".hidden"))
    File.write(File.join(@root, "loose.mkv"), "")
    Dir.mkdir(File.join(@root, "Actual Show"))
    stub_tvmaze_empty

    created = LibraryWatcherService.scan_folder(@shows_folder)
    assert_equal 1, created
  end

  test "movies: indexes both movie files and movie directories" do
    movies_root = Dir.mktmpdir
    movies_folder = MediaFolder.create!(path: movies_root, kind: "movies")
    Dir.mkdir(File.join(movies_root, "Inception (2010)"))
    File.write(File.join(movies_root, "Dune.2021.1080p.mkv"), "")
    File.write(File.join(movies_root, "notes.txt"), "")
    stub_imdb_empty

    created = LibraryWatcherService.scan_folder(movies_folder)
    assert_equal 2, created
    paths = PendingImport.pluck(:folder_path)
    assert_includes paths, File.join(movies_root, "Inception (2010)")
    assert_includes paths, File.join(movies_root, "Dune.2021.1080p.mkv")
  ensure
    FileUtils.remove_entry(movies_root) if movies_root
  end

  test "movies: extracts name and year from filename" do
    movies_root = Dir.mktmpdir
    movies_folder = MediaFolder.create!(path: movies_root, kind: "movies")
    File.write(File.join(movies_root, "Dune.2021.1080p.mkv"), "")
    stub_imdb_empty

    LibraryWatcherService.scan_folder(movies_folder)
    pi = PendingImport.find_by(folder_path: File.join(movies_root, "Dune.2021.1080p.mkv"))
    assert_equal "Dune", pi.parsed_name
    assert_equal 2021, pi.parsed_year
  ensure
    FileUtils.remove_entry(movies_root) if movies_root
  end

  test "falls back to a parens-stripped query when first TVMaze search is empty" do
    Dir.mkdir(File.join(@root, "The Office (UK)"))

    # First call (with parens) returns empty; second call (without parens) returns a hit.
    stub_request(:get, %r{https://api\.tvmaze\.com/search/shows\?q=.*UK})
      .to_return(status: 200, body: "[]", headers: { "Content-Type" => "application/json" })
    stub_request(:get, %r{https://api\.tvmaze\.com/search/shows\?q=The(\+|%20)Office(\?|&|$)})
      .to_return(
        status: 200,
        body: build_tvmaze_results(2).to_json,
        headers: { "Content-Type" => "application/json" }
      )

    LibraryWatcherService.scan_folder(@shows_folder)
    pi = PendingImport.find_by(folder_path: File.join(@root, "The Office (UK)"))
    assert_equal "The Office (UK)", pi.parsed_name, "parsed_name keeps the original folder label"
    assert_operator pi.candidates.size, :>=, 1, "fallback query should produce candidates"
  end

  test "returns 0 when folder path does not exist" do
    ghost = MediaFolder.new(path: "/does/not/exist/#{SecureRandom.hex}", kind: "shows")
    ghost.save(validate: false)
    assert_equal 0, LibraryWatcherService.scan_folder(ghost)
  end

  private

  def stub_tvmaze_empty
    stub_request(:get, %r{https://api\.tvmaze\.com/search/shows}).to_return(
      status: 200, body: "[]", headers: { "Content-Type" => "application/json" }
    )
  end

  def stub_tvmaze_search(_query, results)
    stub_request(:get, %r{https://api\.tvmaze\.com/search/shows}).to_return(
      status: 200, body: results.to_json, headers: { "Content-Type" => "application/json" }
    )
  end

  def stub_imdb_empty
    stub_request(:get, %r{https://api\.imdbapi\.dev/search/titles}).to_return(
      status: 200, body: { titles: [] }.to_json, headers: { "Content-Type" => "application/json" }
    )
  end

  def build_tvmaze_results(count)
    (1..count).map do |i|
      {
        score: (10.0 - i * 0.1),
        show: {
          id: i,
          name: "Result #{i}",
          image: { original: "https://example.com/#{i}.jpg" },
          summary: "<p>Summary #{i}</p>",
          genres: [ "Drama" ],
          rating: { average: 8.0 },
          premiered: "2000-01-01",
          status: "Ended",
          externals: { imdb: "tt000#{i}" }
        }
      }
    end
  end
end
