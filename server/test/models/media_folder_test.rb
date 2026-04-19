require "test_helper"

class MediaFolderTest < ActiveSupport::TestCase
  setup do
    @existing_dir = Dir.mktmpdir
  end

  teardown do
    FileUtils.remove_entry(@existing_dir) if @existing_dir
  end

  test "valid with absolute existing path and allowed kind" do
    folder = MediaFolder.new(path: @existing_dir, kind: "shows")
    assert folder.valid?
  end

  test "requires path" do
    folder = MediaFolder.new(kind: "shows")
    refute folder.valid?
    assert_includes folder.errors[:path], "can't be blank"
  end

  test "requires absolute path" do
    folder = MediaFolder.new(path: "relative/path", kind: "shows")
    refute folder.valid?
    assert_match(/absolute/, folder.errors[:path].join)
  end

  test "requires path to exist on disk" do
    folder = MediaFolder.new(path: "/nonexistent/caramba/#{SecureRandom.hex}", kind: "shows")
    refute folder.valid?
    assert_match(/does not exist/, folder.errors[:path].join)
  end

  test "requires kind inclusion" do
    folder = MediaFolder.new(path: @existing_dir, kind: "anime")
    refute folder.valid?
    assert_match(/not included/, folder.errors[:kind].join)
  end

  test "path must be unique within the same kind" do
    MediaFolder.create!(path: @existing_dir, kind: "shows")
    dup = MediaFolder.new(path: @existing_dir, kind: "shows")
    refute dup.valid?
    assert_match(/taken/, dup.errors[:path].join)
  end

  test "same path is allowed when kind differs" do
    MediaFolder.create!(path: @existing_dir, kind: "shows")
    other_kind = MediaFolder.new(path: @existing_dir, kind: "movies")
    assert other_kind.valid?
    assert other_kind.save
  end

  test "enabled defaults to true" do
    folder = MediaFolder.create!(path: @existing_dir, kind: "shows")
    assert_equal true, folder.enabled
  end

  test "normalizes trailing slash" do
    folder = MediaFolder.create!(path: "#{@existing_dir}/", kind: "shows")
    assert_equal @existing_dir, folder.path
  end

  test "enabled scope excludes disabled folders" do
    enabled = MediaFolder.create!(path: @existing_dir, kind: "shows")
    disabled_dir = Dir.mktmpdir
    disabled = MediaFolder.create!(path: disabled_dir, kind: "movies", enabled: false)
    assert_includes MediaFolder.enabled, enabled
    refute_includes MediaFolder.enabled, disabled
  ensure
    FileUtils.remove_entry(disabled_dir) if disabled_dir
  end
end
