require "test_helper"

class LearningSubtitleTest < ActiveSupport::TestCase
  setup do
    @episode = episodes(:bb_s01e01)
  end

  test "valid with required fields" do
    sub = LearningSubtitle.new(
      media: @episode,
      stream_index: 2,
      language: "eng",
      format: "srt",
      path: "/tmp/sub.srt",
      extracted_at: Time.current
    )
    assert sub.valid?, sub.errors.full_messages.inspect
  end

  test "requires stream_index" do
    sub = LearningSubtitle.new(media: @episode, format: "srt", path: "/x", extracted_at: Time.current)
    assert_not sub.valid?
    assert_includes sub.errors[:stream_index], "can't be blank"
  end

  test "format must be one of srt/vtt/ass" do
    sub = LearningSubtitle.new(media: @episode, stream_index: 1, format: "weird", path: "/x", extracted_at: Time.current)
    assert_not sub.valid?
    assert_includes sub.errors[:format], "is not included in the list"
  end

  test "uniqueness scoped to media + stream_index" do
    LearningSubtitle.create!(media: @episode, stream_index: 3, format: "srt", path: "/a.srt", extracted_at: Time.current)
    dup = LearningSubtitle.new(media: @episode, stream_index: 3, format: "srt", path: "/b.srt", extracted_at: Time.current)
    assert_not dup.valid?
    assert_includes dup.errors[:stream_index], "has already been taken"
  end

  test "different media or different stream_index is allowed" do
    LearningSubtitle.create!(media: @episode, stream_index: 3, format: "srt", path: "/a.srt", extracted_at: Time.current)
    other_idx = LearningSubtitle.new(media: @episode, stream_index: 4, format: "srt", path: "/b.srt", extracted_at: Time.current)
    other_ep = LearningSubtitle.new(media: episodes(:bb_s01e02), stream_index: 3, format: "srt", path: "/c.srt", extracted_at: Time.current)
    assert other_idx.valid?
    assert other_ep.valid?
  end

  test "Episode#learning_subtitles association works and cascades on destroy" do
    sub = LearningSubtitle.create!(media: @episode, stream_index: 5, format: "srt", path: "/x.srt", extracted_at: Time.current)
    assert_equal 1, @episode.learning_subtitles.where(id: sub.id).count
    @episode.destroy!
    assert_nil LearningSubtitle.find_by(id: sub.id)
  end
end
