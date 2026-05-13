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

  # select_subtitle_track returns [stream_index, burn_required]. The
  # burn-required flag is true when the file's subtitle format is NOT in
  # the client's SubtitleProfiles — server must burn it in via overlay
  # filter. Otherwise false: server delivers via VTT sidecar (External)
  # or leaves it muxed (Embed).
  class SubtitleSelectionTest < ActiveSupport::TestCase
    setup do
      @controller = Api::PlaybackController.new
    end

    def select(streams, prefs = nil, profile = browser_profile)
      @controller.send(:select_subtitle_track, streams, prefs, profile)
    end

    # Browser profile: VTT External only. Bitmap subs require burn-in.
    def browser_profile
      {
        "DirectPlayProfiles" => [],
        "TranscodingProfiles" => [],
        "SubtitleProfiles" => [ { "Format" => "vtt", "Method" => "External" } ],
        "CodecProfiles" => []
      }
    end

    # Native-player profile: PGSSUB Embed + srt External.
    def native_profile
      {
        "DirectPlayProfiles" => [],
        "TranscodingProfiles" => [],
        "SubtitleProfiles" => [
          { "Format" => "PGSSUB", "Method" => "Embed" },
          { "Format" => "srt", "Method" => "External" }
        ],
        "CodecProfiles" => []
      }
    end

    test "returns [nil, false] when no streams" do
      assert_equal [ nil, false ], select([])
    end

    test "returns [nil, false] when only bitmap streams and no prefs" do
      streams = [
        { index: 2, codec: "hdmv_pgs_subtitle", language: "eng", isText: false }
      ]
      # No prefs and no text sub → pick_subtitle_track returns nil →
      # nothing selected. Auto-skip remains for the no-pref + no-text case.
      assert_equal [ nil, false ], select(streams)
    end

    test "returns [nil, false] when subtitleOff is set" do
      streams = [
        { index: 2, codec: "subrip", language: "eng", isText: true }
      ]
      assert_equal [ nil, false ], select(streams, { subtitleOff: true })
    end

    test "auto-picks text subtitle when both text and bitmap exist" do
      streams = [
        { index: 2, codec: "hdmv_pgs_subtitle", language: "eng", isText: false },
        { index: 3, codec: "subrip", language: "eng", isText: true }
      ]
      # Browser profile: srt is NOT in SubtitleProfiles, but text subs
      # always fall through to VTT extraction rather than burn-in (the
      # ffmpeg burn-in filter uses `overlay` which only works on bitmap
      # streams). burn_required=false → server extracts as WebVTT sidecar.
      assert_equal [ 3, false ], select(streams)
    end

    test "auto-picked srt → burn_required=false on native profile (srt External)" do
      streams = [
        { index: 3, codec: "subrip", language: "eng", isText: true }
      ]
      assert_equal [ 3, false ], select(streams, nil, native_profile)
    end

    test "saved bitmap preference + browser profile → bitmap selected, burn_required=true" do
      streams = [
        { index: 4, codec: "hdmv_pgs_subtitle", language: "eng", isText: false }
      ]
      assert_equal [ 4, true ], select(streams, { subtitleLanguage: "eng" })
    end

    test "saved bitmap preference + native profile (PGSSUB Embed) → bitmap selected, burn_required=false" do
      streams = [
        { index: 4, codec: "hdmv_pgs_subtitle", language: "eng", isText: false }
      ]
      assert_equal [ 4, false ], select(streams, { subtitleLanguage: "eng" }, native_profile)
    end

    test "saved text preference wins over bitmap of same language" do
      streams = [
        { index: 5, codec: "hdmv_pgs_subtitle", language: "eng", isText: false },
        { index: 6, codec: "subrip", language: "eng", isText: true }
      ]
      # Native profile: srt External → no burn.
      assert_equal [ 6, false ], select(streams, { subtitleLanguage: "eng" }, native_profile)
    end
  end

  # select_audio_track has to disambiguate same-language tracks (TrueHD eng
  # + AC3 eng on UHD remuxes) and even same-language same-codec tracks
  # (AAC stereo + AAC 5.1 from a single source). Three-key match. The
  # "supported codec" check now consults the client's DeviceProfile.
  class AudioSelectionTest < ActiveSupport::TestCase
    setup do
      @controller = Api::PlaybackController.new
    end

    def select(streams, prefs = nil, profile = aac_only_profile)
      @controller.send(:select_audio_track, streams, prefs, profile)
    end

    # Profile with only AAC in DirectPlayProfiles.AudioCodec.
    def aac_only_profile
      {
        "DirectPlayProfiles" => [ {
          "Container" => "mp4", "Type" => "Video",
          "VideoCodec" => "h264", "AudioCodec" => "aac"
        } ]
      }
    end

    # Profile that lists AC3 as direct-playable.
    def ac3_profile
      {
        "DirectPlayProfiles" => [ {
          "Container" => "mp4,mkv", "Type" => "Video",
          "VideoCodec" => "h264", "AudioCodec" => "aac,ac3"
        } ]
      }
    end

    def aac_streams
      [
        { index: 1, codec: "aac", channels: 6, language: "eng" },
        { index: 2, codec: "aac", channels: 2, language: "eng" }
      ]
    end

    test "saved (lang, codec, channels) finds the exact stereo track among AAC siblings" do
      assert_equal 2, select(aac_streams, {
        audioLanguage: "eng", audioCodec: "aac", audioChannels: 2
      })
    end

    test "saved (lang, codec, channels) finds the exact 5.1 track among AAC siblings" do
      assert_equal 1, select(aac_streams, {
        audioLanguage: "eng", audioCodec: "aac", audioChannels: 6
      })
    end

    test "saved (lang, codec) without channels falls back to first language+codec match" do
      assert_equal 1, select(aac_streams, { audioLanguage: "eng", audioCodec: "aac" })
    end

    test "exact (lang, codec, channels) miss falls through to lang+codec" do
      streams = [
        { index: 1, codec: "truehd", channels: 8, language: "eng" },
        { index: 2, codec: "ac3",    channels: 6, language: "eng" }
      ]
      result = select(streams, {
        audioLanguage: "eng", audioCodec: "aac", audioChannels: 2
      }, ac3_profile)
      assert_equal 2, result, "should land on the AC3 track because profile decodes it"
    end

    test "no saved prefs: prefers a profile-decodable codec in the desired language" do
      streams = [
        { index: 1, codec: "truehd", channels: 8, language: "eng" },
        { index: 2, codec: "ac3",    channels: 6, language: "eng" }
      ]
      assert_equal 2, select(streams, nil, ac3_profile)
    end

    test "no saved prefs and nothing playable: first language match wins" do
      streams = [
        { index: 1, codec: "truehd", channels: 8, language: "eng" },
        { index: 2, codec: "dts",    channels: 6, language: "eng" }
      ]
      assert_equal 1, select(streams, nil, aac_only_profile)
    end

    test "nothing playable: prefers AC3 over TrueHD even when TrueHD is first" do
      # On a profile with only AAC, neither track is direct-passable but
      # AC3 still re-encodes to AAC much faster than TrueHD. Auto-pick
      # should bias toward AC3 to keep cold start under the wait window.
      streams = [
        { index: 1, codec: "truehd", channels: 8, language: "eng" },
        { index: 2, codec: "ac3",    channels: 6, language: "eng" }
      ]
      assert_equal 2, select(streams, nil, aac_only_profile)
    end

    test "nothing playable, nothing cheap: falls back to first" do
      streams = [
        { index: 1, codec: "truehd",  channels: 8, language: "eng" },
        { index: 2, codec: "dts_hd",  channels: 6, language: "eng" }
      ]
      assert_equal 1, select(streams, nil, aac_only_profile)
    end
  end

  # Regression: derive_strategy reads `decision.method`, not predicate methods.
  # PlaybackInfo.for returns a Response struct whose mode lives on `.method`
  # (`:direct_play` / `:direct_stream` / `:transcode`). An earlier version
  # called `decision.direct_play?` which raised NoMethodError at runtime —
  # caught only by the user trying to play something. These tests pin the
  # mapping for every mode against the actual struct the engine returns.
  class StrategyMappingTest < ActiveSupport::TestCase
    setup do
      @controller = Api::PlaybackController.new
    end

    def response_with(mode)
      Jellyfin::Playback::PlaybackInfo::Response.new(method: mode)
    end

    def info
      {
        video: { codec: "h264" },
        audioStreams: [ { index: 1, codec: "aac", channels: 2, language: "eng" } ]
      }
    end

    def profile
      p = Jellyfin::Playback::ClientProfile.modern_browser
      p.video_codecs = %w[h264]
      p.audio_codecs = %w[aac]
      p
    end

    def derive(mode, is_bitmap: false, audio_idx: 1, info_override: nil, profile_override: nil)
      @controller.send(:derive_strategy,
        response_with(mode),
        info_override || info,
        audio_idx,
        profile_override || profile,
        is_bitmap)
    end

    test ":direct_play decision maps to 'direct_play'" do
      assert_equal "direct_play", derive(:direct_play)
    end

    test ":direct_stream decision maps to 'direct_stream'" do
      assert_equal "direct_stream", derive(:direct_stream)
    end

    test "burn-in forces 'full_transcode' regardless of decision" do
      assert_equal "full_transcode", derive(:transcode, is_bitmap: true)
    end

    test ":transcode with audio-only re-encode maps to 'audio_transcode'" do
      # Video codec direct-playable, audio codec NOT in profile → audio-only.
      bad_audio_info = info.deep_dup
      bad_audio_info[:audioStreams] = [ { index: 1, codec: "truehd", channels: 8, language: "eng" } ]
      assert_equal "audio_transcode", derive(:transcode, info_override: bad_audio_info)
    end

    test ":transcode with video re-encode maps to 'full_transcode'" do
      # Video codec NOT in profile → full transcode.
      bad_video_info = info.deep_dup
      bad_video_info[:video] = { codec: "hevc" }
      assert_equal "full_transcode", derive(:transcode, info_override: bad_video_info)
    end

    test "Response struct exposes mode via .method (regression for predicate-call bug)" do
      # Lock the contract: if upstream renames .method or adds predicate
      # methods, this test should be the first thing to fail.
      r = Jellyfin::Playback::PlaybackInfo::Response.new(method: :direct_play)
      assert_equal :direct_play, r.method
      assert_not_respond_to r, :direct_play?
    end
  end
end
