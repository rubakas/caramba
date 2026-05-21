require "test_helper"

class LessonTest < ActiveSupport::TestCase
  setup do
    @episode = episodes(:bb_s01e01)
    @movie = movies(:inception)
    @subtitle = LearningSubtitle.create!(
      media: @episode, stream_index: 2, language: "eng", format: "srt",
      path: "/tmp/x.srt", extracted_at: Time.current
    )
  end

  test "valid with episode + source_subtitle" do
    lesson = Lesson.new(episode: @episode, source_subtitle: @subtitle)
    assert lesson.valid?, lesson.errors.full_messages.inspect
  end

  test "valid with movie + source_subtitle" do
    lesson = Lesson.new(movie: @movie, source_subtitle: @subtitle)
    assert lesson.valid?
  end

  test "invalid when neither episode nor movie set" do
    lesson = Lesson.new(source_subtitle: @subtitle)
    assert_not lesson.valid?
    assert_includes lesson.errors[:base], "must reference an episode or a movie"
  end

  test "invalid when both episode and movie set" do
    lesson = Lesson.new(episode: @episode, movie: @movie, source_subtitle: @subtitle)
    assert_not lesson.valid?
    assert_includes lesson.errors[:base], "cannot reference both an episode and a movie"
  end

  test "rejects unknown status" do
    lesson = Lesson.new(episode: @episode, source_subtitle: @subtitle, status: "weird")
    assert_not lesson.valid?
    assert_includes lesson.errors[:status], "is not included in the list"
  end

  test "rejects unknown provider" do
    lesson = Lesson.new(episode: @episode, source_subtitle: @subtitle, provider: "fanlang")
    assert_not lesson.valid?
    assert_includes lesson.errors[:provider], "is not included in the list"
  end

  test "destroying an Episode cascades to its Lessons" do
    lesson = Lesson.create!(episode: @episode, source_subtitle: @subtitle)
    @episode.destroy!
    assert_nil Lesson.find_by(id: lesson.id)
  end
end
