require "test_helper"

class Api::PlaybackControllerTest < ActionDispatch::IntegrationTest
  test "report_progress updates episode progress" do
    ep = episodes(:bb_s02e01)

    post "/api/playback/report_progress", params: {
      episode_id: ep.id,
      time: 500,
      duration: 3000
    }
    assert_response :success

    data = JSON.parse(response.body)
    assert_equal 500, data["absoluteTime"]

    ep.reload
    assert_equal 500, ep.progress_seconds
    assert_equal 3000, ep.duration_seconds
  end

  test "report_progress auto-marks watched at 90%" do
    ep = episodes(:bb_s01e02)

    post "/api/playback/report_progress", params: {
      episode_id: ep.id,
      time: 2700,
      duration: 2880
    }
    assert_response :success

    ep.reload
    assert ep.watched?
  end

  test "report_progress updates movie progress" do
    movie = movies(:inception)

    post "/api/playback/report_progress", params: {
      movie_id: movie.id,
      time: 3000,
      duration: 8880
    }
    assert_response :success

    movie.reload
    assert_equal 3000, movie.progress_seconds
  end

  test "report_progress returns 422 with zero duration" do
    post "/api/playback/report_progress", params: {
      episode_id: episodes(:bb_s02e01).id,
      time: 100,
      duration: 0
    }
    assert_response :unprocessable_entity
  end

  test "report_progress updates watch_history" do
    wh = watch_histories(:history_two)
    ep = episodes(:bb_s01e02)

    post "/api/playback/report_progress", params: {
      episode_id: ep.id,
      watch_history_id: wh.id,
      time: 2000,
      duration: 2880
    }
    assert_response :success

    wh.reload
    assert_equal 2000, wh.progress_seconds
  end

  test "preferences returns playback prefs for show" do
    get "/api/playback/preferences", params: {
      type: "episode",
      show_id: shows(:breaking_bad).id
    }
    assert_response :success

    data = JSON.parse(response.body)
    assert_equal "eng", data["audioLanguage"]
    assert_equal "eng", data["subtitleLanguage"]
  end

  test "preferences returns playback prefs for movie" do
    get "/api/playback/preferences", params: {
      type: "movie",
      movie_id: movies(:the_matrix).id
    }
    assert_response :success

    data = JSON.parse(response.body)
    assert_equal "eng", data["audioLanguage"]
    assert_equal true, data["subtitleOff"]
  end

  test "preferences returns null when not found" do
    get "/api/playback/preferences", params: {
      type: "episode",
      show_id: shows(:no_metadata).id
    }
    assert_response :success
    assert_equal "null", response.body.strip
  end

  test "save_preferences creates/updates prefs for show" do
    post "/api/playback/preferences", params: {
      type: "episode",
      showId: shows(:the_office).id,
      audioLanguage: "jpn",
      subtitleLanguage: "eng",
      subtitleOff: false,
      subtitleSize: "small",
      subtitleStyle: "modern"
    }
    assert_response :success

    pref = PlaybackPreference.find_by(show_id: shows(:the_office).id)
    assert_not_nil pref
    assert_equal "jpn", pref.audio_language
    assert_equal "small", pref.subtitle_size
  end

  test "save_preferences creates/updates prefs for movie" do
    post "/api/playback/preferences", params: {
      type: "movie",
      movieId: movies(:inception).id,
      audioLanguage: "fre",
      subtitleLanguage: "fre",
      subtitleOff: true,
      subtitleSize: "large",
      subtitleStyle: "classic"
    }
    assert_response :success

    pref = PlaybackPreference.find_by(movie_id: movies(:inception).id)
    assert_not_nil pref
    assert_equal "fre", pref.audio_language
  end

  # select_subtitle_track guards against auto-picking bitmap (PGS/VOBSUB)
  # tracks. Auto-burn forces full_transcode → encode <1× realtime on 4K → the
  # client sees a request storm.
  class SubtitleSelectionTest < ActiveSupport::TestCase
    setup do
      @controller = Api::PlaybackController.new
    end

    def select(streams, prefs = nil)
      @controller.send(:select_subtitle_track, streams, prefs)
    end

    test "returns [nil, false] when no streams" do
      assert_equal [ nil, false ], select([])
    end

    test "returns [nil, false] when only bitmap streams and no prefs" do
      streams = [
        { index: 2, language: "eng", isText: false }
      ]
      assert_equal [ nil, false ], select(streams)
    end

    test "returns [nil, false] when only bitmap streams and subtitleOff" do
      streams = [
        { index: 2, language: "eng", isText: false }
      ]
      assert_equal [ nil, false ], select(streams, { subtitleOff: true })
    end

    test "auto-picks text subtitle when both text and bitmap exist" do
      streams = [
        { index: 2, language: "eng", isText: false },
        { index: 3, language: "eng", isText: true }
      ]
      assert_equal [ 3, false ], select(streams)
    end

    test "honors saved bitmap preference when language matches" do
      streams = [
        { index: 4, language: "eng", isText: false }
      ]
      assert_equal [ 4, true ], select(streams, { subtitleLanguage: "eng" })
    end

    test "saved text preference wins over bitmap of same language" do
      streams = [
        { index: 5, language: "eng", isText: false },
        { index: 6, language: "eng", isText: true }
      ]
      assert_equal [ 6, false ], select(streams, { subtitleLanguage: "eng" })
    end

    test "saved language with only bitmap streams selects bitmap" do
      streams = [
        { index: 7, language: "fre", isText: false }
      ]
      assert_equal [ 7, true ], select(streams, { subtitleLanguage: "fre" })
    end
  end
end
