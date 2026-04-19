require "test_helper"

class FilesystemBrowserServiceTest < ActiveSupport::TestCase
  setup do
    @root = Dir.mktmpdir
    Dir.mkdir(File.join(@root, "series"))
    Dir.mkdir(File.join(@root, "movies"))
    Dir.mkdir(File.join(@root, "AA_at_top"))
    File.write(File.join(@root, "readme.txt"), "should be filtered out")
  end

  teardown do
    FileUtils.remove_entry(@root) if @root
  end

  test "list_mounts includes Home and Root" do
    mounts = FilesystemBrowserService.list_mounts
    assert mounts.any? { |m| m["name"] == "Home" }
    assert mounts.any? { |m| m["name"] == "Root" && m["path"] == "/" }
  end

  test "list_entries returns only directories" do
    listing = FilesystemBrowserService.list_entries(@root)
    names = listing["entries"].map { |e| e["name"] }
    assert_includes names, "series"
    assert_includes names, "movies"
    refute_includes names, "readme.txt"
  end

  test "list_entries sorts case-insensitive" do
    listing = FilesystemBrowserService.list_entries(@root)
    names = listing["entries"].map { |e| e["name"] }
    assert_equal names, names.sort_by(&:downcase)
  end

  test "list_entries returns parent for non-root path" do
    listing = FilesystemBrowserService.list_entries(@root)
    assert_equal File.dirname(File.realpath(@root)), listing["parent"]
  end

  test "list_entries rejects relative path" do
    err = assert_raises(FilesystemBrowserService::InvalidPath) do
      FilesystemBrowserService.list_entries("relative/path")
    end
    assert_match(/absolute/, err.message)
  end

  test "list_entries rejects non-existent path" do
    err = assert_raises(FilesystemBrowserService::InvalidPath) do
      FilesystemBrowserService.list_entries("/nonexistent/caramba/#{SecureRandom.hex}")
    end
    assert_match(/does not exist/, err.message)
  end

  test "list_entries rejects blank path" do
    assert_raises(FilesystemBrowserService::InvalidPath) do
      FilesystemBrowserService.list_entries("")
    end
  end

  test "list_entries rejects symlink into forbidden root" do
    symlink = File.join(@root, "sneaky")
    File.symlink("/etc", symlink)
    err = assert_raises(FilesystemBrowserService::InvalidPath) do
      FilesystemBrowserService.list_entries(symlink)
    end
    assert_match(/not permitted/, err.message)
  end

  test "list_entries rejects a file (not a directory)" do
    file_path = File.join(@root, "readme.txt")
    err = assert_raises(FilesystemBrowserService::InvalidPath) do
      FilesystemBrowserService.list_entries(file_path)
    end
    assert_match(/not a directory/, err.message)
  end

  test "list_entries returns realpath for symlinks pointing to permitted targets" do
    target = Dir.mktmpdir
    symlink = File.join(@root, "link_to_tmp")
    File.symlink(target, symlink)
    listing = FilesystemBrowserService.list_entries(symlink)
    assert_equal File.realpath(target), listing["path"]
  ensure
    FileUtils.remove_entry(target) if target
  end
end
