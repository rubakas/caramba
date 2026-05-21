require "test_helper"

class PhraseTest < ActiveSupport::TestCase
  setup do
    @episode = episodes(:bb_s01e01)
    @sub = LearningSubtitle.create!(
      media: @episode, stream_index: 2, language: "eng", format: "srt",
      path: "/tmp/x.srt", extracted_at: Time.current
    )
    @lesson = Lesson.create!(episode: @episode, source_subtitle: @sub)
  end

  test "valid with required fields" do
    p = Phrase.new(lesson: @lesson, position: 1, phrase: "hi", start_ms: 0, end_ms: 1000)
    assert p.valid?, p.errors.full_messages.inspect
  end

  test "requires phrase text" do
    p = Phrase.new(lesson: @lesson, position: 1, start_ms: 0, end_ms: 1000)
    assert_not p.valid?
    assert_includes p.errors[:phrase], "can't be blank"
  end

  test "end_ms must be greater than start_ms" do
    p = Phrase.new(lesson: @lesson, position: 1, phrase: "hi", start_ms: 5000, end_ms: 5000)
    assert_not p.valid?
    assert_includes p.errors[:end_ms], "must be greater than start_ms"
  end

  test "rejects unknown clip_status" do
    p = Phrase.new(lesson: @lesson, position: 1, phrase: "hi", start_ms: 0, end_ms: 1000, clip_status: "weird")
    assert_not p.valid?
    assert_includes p.errors[:clip_status], "is not included in the list"
  end

  test "position is unique within a lesson" do
    Phrase.create!(lesson: @lesson, position: 1, phrase: "first", start_ms: 0, end_ms: 1000)
    dup = Phrase.new(lesson: @lesson, position: 1, phrase: "second", start_ms: 2000, end_ms: 3000)
    assert_not dup.valid?
    assert_includes dup.errors[:position], "has already been taken"
  end

  test "duration_ms returns the span" do
    p = Phrase.new(start_ms: 1000, end_ms: 4500)
    assert_equal 3500, p.duration_ms
  end
end
