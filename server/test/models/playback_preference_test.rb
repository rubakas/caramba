require "test_helper"

class PlaybackPreferenceTest < ActiveSupport::TestCase
  test "fixtures load" do
    pref = playback_preferences(:bb_prefs)
    assert_equal "eng", pref.audio_language
    assert_equal series(:breaking_bad), pref.series
  end

  test "validates series_or_movie_present" do
    pref = PlaybackPreference.new(audio_language: "eng")
    assert_not pref.valid?
    assert pref.errors[:base].any? { |e| e.include?("must belong to") }
  end

  test "cannot belong to both series and movie" do
    pref = PlaybackPreference.new(
      series: series(:the_office),
      movie: movies(:inception),
      audio_language: "eng"
    )
    assert_not pref.valid?
    assert pref.errors[:base].any? { |e| e.include?("cannot belong to both") }
  end

  test "series_id uniqueness" do
    pref = PlaybackPreference.new(series: series(:breaking_bad), audio_language: "jpn")
    assert_not pref.valid?
    assert_includes pref.errors[:series_id], "has already been taken"
  end

  test "movie_id uniqueness" do
    pref = PlaybackPreference.new(movie: movies(:the_matrix), audio_language: "jpn")
    assert_not pref.valid?
    assert_includes pref.errors[:movie_id], "has already been taken"
  end

  test "can create for movie without series" do
    pref = PlaybackPreference.new(movie: movies(:inception), audio_language: "eng")
    assert pref.valid?
  end
end
