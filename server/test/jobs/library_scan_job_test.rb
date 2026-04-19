require "test_helper"

class LibraryScanJobTest < ActiveJob::TestCase
  test "scans enabled folders and creates pending imports, skips disabled" do
    enabled_dir = Dir.mktmpdir
    disabled_dir = Dir.mktmpdir
    Dir.mkdir(File.join(enabled_dir, "Some Show"))
    Dir.mkdir(File.join(disabled_dir, "Another Show"))

    MediaFolder.create!(path: enabled_dir, kind: "shows", enabled: true)
    MediaFolder.create!(path: disabled_dir, kind: "shows", enabled: false)

    stub_request(:get, %r{api\.tvmaze\.com/search/shows}).to_return(
      status: 200, body: "[]", headers: { "Content-Type" => "application/json" }
    )

    LibraryScanJob.perform_now

    assert PendingImport.exists?(folder_path: File.join(enabled_dir, "Some Show"))
    refute PendingImport.exists?(folder_path: File.join(disabled_dir, "Another Show"))
  ensure
    FileUtils.remove_entry(enabled_dir) if enabled_dir
    FileUtils.remove_entry(disabled_dir) if disabled_dir
  end

  test "can be enqueued via perform_later" do
    assert_enqueued_with(job: LibraryScanJob) do
      LibraryScanJob.perform_later
    end
  end
end
