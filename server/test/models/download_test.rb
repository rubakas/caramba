require "test_helper"

class DownloadTest < ActiveSupport::TestCase
  test "fixtures load" do
    dl = downloads(:bb_ep_download)
    assert_equal "complete", dl.status
    assert_equal episodes(:bb_s01e01), dl.episode
  end

  test "validates file_path presence" do
    dl = Download.new(episode: episodes(:bb_s01e02), status: "pending")
    assert_not dl.valid?
    assert_includes dl.errors[:file_path], "can't be blank"
  end

  test "validates status inclusion" do
    dl = Download.new(episode: episodes(:bb_s01e02), file_path: "/tmp/x.mkv", status: "bogus")
    assert_not dl.valid?
    assert_includes dl.errors[:status], "is not included in the list"
  end

  test "episode_or_movie_present validation" do
    dl = Download.new(file_path: "/tmp/x.mkv", status: "pending")
    assert_not dl.valid?
    assert dl.errors[:base].any? { |e| e.include?("must belong to") }
  end

  test "cannot belong to both episode and movie" do
    dl = Download.new(
      episode: episodes(:bb_s01e02),
      movie: movies(:inception),
      file_path: "/tmp/x.mkv",
      status: "pending"
    )
    assert_not dl.valid?
    assert dl.errors[:base].any? { |e| e.include?("cannot belong to both") }
  end

  test "episode_id uniqueness" do
    dl = Download.new(episode: episodes(:bb_s01e01), file_path: "/tmp/dup.mkv", status: "pending")
    assert_not dl.valid?
    assert_includes dl.errors[:episode_id], "has already been taken"
  end

  test "total_size sums complete downloads" do
    assert Download.total_size > 0
  end

  test "complete scope" do
    assert_includes Download.complete, downloads(:bb_ep_download)
    assert_not_includes Download.complete, downloads(:matrix_download)
  end
end
