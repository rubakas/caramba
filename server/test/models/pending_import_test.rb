require "test_helper"

class PendingImportTest < ActiveSupport::TestCase
  setup do
    @existing_dir = Dir.mktmpdir
    @folder = MediaFolder.create!(path: @existing_dir, kind: "shows")
  end

  teardown do
    FileUtils.remove_entry(@existing_dir) if @existing_dir
  end

  test "valid with required fields" do
    pi = PendingImport.new(
      media_folder: @folder,
      folder_path: "#{@existing_dir}/Breaking Bad",
      kind: "shows"
    )
    assert pi.valid?
  end

  test "defaults status to pending" do
    pi = PendingImport.create!(
      media_folder: @folder,
      folder_path: "#{@existing_dir}/show1",
      kind: "shows"
    )
    assert_equal "pending", pi.status
  end

  test "rejects unknown status" do
    pi = PendingImport.new(
      media_folder: @folder,
      folder_path: "#{@existing_dir}/show1",
      kind: "shows",
      status: "bogus"
    )
    refute pi.valid?
  end

  test "rejects unknown kind" do
    pi = PendingImport.new(
      media_folder: @folder,
      folder_path: "#{@existing_dir}/show1",
      kind: "anime"
    )
    refute pi.valid?
  end

  test "folder_path must be unique" do
    PendingImport.create!(
      media_folder: @folder,
      folder_path: "#{@existing_dir}/show1",
      kind: "shows"
    )
    dup = PendingImport.new(
      media_folder: @folder,
      folder_path: "#{@existing_dir}/show1",
      kind: "shows"
    )
    refute dup.valid?
  end

  test "serializes candidates as JSON array" do
    pi = PendingImport.create!(
      media_folder: @folder,
      folder_path: "#{@existing_dir}/show1",
      kind: "shows",
      candidates: [ { "externalId" => 169, "name" => "Breaking Bad" } ]
    )
    pi.reload
    assert_equal 169, pi.candidates.first["externalId"]
    assert_equal "Breaking Bad", pi.candidates.first["name"]
  end

  test "cascade deletes when media_folder destroyed" do
    PendingImport.create!(
      media_folder: @folder,
      folder_path: "#{@existing_dir}/show1",
      kind: "shows"
    )
    assert_difference("PendingImport.count", -1) do
      @folder.destroy
    end
  end

  test "pending scope excludes non-pending statuses" do
    p1 = PendingImport.create!(
      media_folder: @folder,
      folder_path: "#{@existing_dir}/show1",
      kind: "shows"
    )
    confirmed = PendingImport.create!(
      media_folder: @folder,
      folder_path: "#{@existing_dir}/show2",
      kind: "shows",
      status: "confirmed"
    )
    assert_includes PendingImport.pending, p1
    refute_includes PendingImport.pending, confirmed
  end
end
