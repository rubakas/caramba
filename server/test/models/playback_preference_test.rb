require "test_helper"

class PlaybackPreferenceTest < ActiveSupport::TestCase
  test "fixtures load" do
    pref = playback_preferences(:bb_prefs)
    assert_equal "eng", pref.audio_language
    assert_equal shows(:breaking_bad), pref.show
  end

  test "validates show_or_movie_present" do
    pref = PlaybackPreference.new(audio_language: "eng")
    assert_not pref.valid?
    assert pref.errors[:base].any? { |e| e.include?("must belong to") }
  end

  test "cannot belong to both show and movie" do
    pref = PlaybackPreference.new(
      show: shows(:the_office),
      movie: movies(:inception),
      audio_language: "eng"
    )
    assert_not pref.valid?
    assert pref.errors[:base].any? { |e| e.include?("cannot belong to both") }
  end

  test "show_id uniqueness" do
    pref = PlaybackPreference.new(show: shows(:breaking_bad), audio_language: "jpn")
    assert_not pref.valid?
    assert_includes pref.errors[:show_id], "has already been taken"
  end

  test "movie_id uniqueness" do
    pref = PlaybackPreference.new(movie: movies(:the_matrix), audio_language: "jpn")
    assert_not pref.valid?
    assert_includes pref.errors[:movie_id], "has already been taken"
  end

  test "can create for movie without show" do
    pref = PlaybackPreference.new(movie: movies(:inception), audio_language: "eng")
    assert pref.valid?
  end
end
