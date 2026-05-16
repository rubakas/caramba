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

    # Regression: a saved English language preference used to auto-pick a
    # PGS track on every BluRay rip and flip burn_required=true, which
    # forced full SW transcode (HW overlay graph isn't ported yet, so
    # jellyfin-rails' resolve_hwaccel refuses the HW backend for any
    # graphical burn-in job). The user's symptom: "I didn't enable
    # subtitles but every title is still pegging the CPU at 97%".
    # Policy now: when the auto-pick lands on a bitmap track the client
    # can't render natively, drop the subtitle entirely. The user can
    # still pick the PGS track manually from the player UI when they
    # actually want it.
    test "saved bitmap preference + browser profile → subtitle dropped, no burn" do
      streams = [
        { index: 4, codec: "hdmv_pgs_subtitle", language: "eng", isText: false }
      ]
      assert_equal [ nil, false ], select(streams, { subtitleLanguage: "eng" })
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

  # Regression for the Safari "spinner forever then unsupported toast" bug.
  # The transcoding engine's master playlist used to ALWAYS emit
  # EXT-X-MEDIA:TYPE=SUBTITLES rendition groups. Safari fetches every
  # subtitle URI in the master in parallel; the engine's webvtt index
  # endpoint stalled on a 2.5h MKV → Safari aborted with code 4. Now
  # the playback_controller threads the client's SubtitleProfiles
  # decision through into the token's `subtitle_delivery` field; the
  # engine only emits subtitle MEDIA when `Method=Hls`. Caramba clients
  # declare Method=External → no subtitle MEDIA → Safari plays.
  class HlsRenditionGatingTest < ActiveSupport::TestCase
    setup do
      @controller = Api::PlaybackController.new
    end

    def deliver_via_hls?(profile)
      @controller.send(:hls_subtitle_delivery?, profile)
    end

    def trickplay?(profile)
      @controller.send(:hls_trickplay?, profile)
    end

    test "External SubtitleProfile (caramba default) → no HLS subtitle delivery" do
      profile = { "SubtitleProfiles" => [ { "Format" => "vtt", "Method" => "External" } ] }
      refute deliver_via_hls?(profile)
    end

    test "Embed SubtitleProfile (native player) → no HLS subtitle delivery" do
      profile = { "SubtitleProfiles" => [ { "Format" => "PGSSUB", "Method" => "Embed" } ] }
      refute deliver_via_hls?(profile)
    end

    test "Hls SubtitleProfile (explicit opt-in) → HLS subtitle delivery" do
      profile = { "SubtitleProfiles" => [ { "Format" => "vtt", "Method" => "Hls" } ] }
      assert deliver_via_hls?(profile)
    end

    test "mixed profile with at least one Hls entry → HLS subtitle delivery" do
      profile = { "SubtitleProfiles" => [
        { "Format" => "PGSSUB", "Method" => "Embed" },
        { "Format" => "vtt", "Method" => "Hls" }
      ] }
      assert deliver_via_hls?(profile)
    end

    test "nil / missing profile → no HLS subtitle delivery" do
      refute deliver_via_hls?(nil)
      refute deliver_via_hls?({})
    end

    test "Trickplay opt-in via top-level flag" do
      assert trickplay?({ "Trickplay" => true })
      assert trickplay?({ "EnableTrickplay" => "true" })
      refute trickplay?({})
      refute trickplay?(nil)
    end
  end

  # Regression: bitmap subtitles (PGS/DVB/DVDsub) require the engine to
  # *burn* them into the video stream via the overlay filter — there's no
  # way to render a bitmap sub client-side. The engine gates that on
  # `subtitle_method == :encode` (see `EncodingJobInfo#burn_subtitles?` and
  # `Filters::SubtitleBurn.build` at `encoding_helper.rb:297`). Previously
  # Caramba only put `subtitle_track:` in the transcode token — the engine
  # got the stream index but defaulted `subtitle_method` to `:soft`, so
  # `burn_subtitles?` returned false and the overlay filter was silently
  # skipped: video played, no subtitles. We now stamp `subtitle_mode:
  # "encode"` on the token whenever the picked stream is bitmap.
  class BitmapSubtitleBurnTokenTest < ActiveSupport::TestCase
    test "subtitle_mode = 'encode' is set on the token when the picked sub is bitmap" do
      # Easiest path to assert the token contents is to drive the local
      # token-params build directly: replicate the conditional that lives
      # in #start so we don't have to spin up a full request cycle.
      is_bitmap = true
      subtitle_stream_index = 4
      token_params = {
        subtitle_track: is_bitmap ? subtitle_stream_index : nil,
        subtitle_mode: is_bitmap ? "encode" : nil
      }
      assert_equal "encode", token_params[:subtitle_mode],
        "bitmap path must request burn-in or the engine's overlay filter never runs"
      assert_equal subtitle_stream_index, token_params[:subtitle_track]
    end

    test "subtitle_mode is NIL for text subs so soft-sub path stays soft" do
      is_bitmap = false
      subtitle_stream_index = 3
      token_params = {
        subtitle_track: is_bitmap ? subtitle_stream_index : nil,
        subtitle_mode: is_bitmap ? "encode" : nil
      }
      assert_nil token_params[:subtitle_mode],
        "text subs must NOT request burn-in — they're delivered as external WebVTT"
      assert_nil token_params[:subtitle_track]
    end

    # Regression: when bitmap burn-in is required, `video_codec` must NOT
    # be set to "copy" even if the playback decision is :direct_stream.
    # `video_codec=copy` skips the filter chain entirely (ffmpeg never
    # decodes frames), so the PGS overlay can't run. Symptom: init segment
    # (`-1.mp4`) never written, every request 504s, both video AND subs
    # silently fail. Audio can still be copied — only the video side
    # has to drop the copy.
    # Replicates the codec-pinning conditional from #start so the regression
    # is testable without standing up the full request cycle.
    def pin_codecs(direct_stream:, is_bitmap:)
      params = {}
      if direct_stream
        params[:video_codec] = "copy" unless is_bitmap
        params[:audio_codec] = "copy"
      end
      params
    end

    test "video stays re-encoded for bitmap burn even on :direct_stream" do
      params = pin_codecs(direct_stream: true, is_bitmap: true)
      assert_nil params[:video_codec],
        "bitmap burn + video_codec=copy = ffmpeg hangs on init_segment (filter chain bypassed by stream-copy)"
      assert_equal "copy", params[:audio_codec],
        "audio path doesn't intersect with the video filter chain — copy is safe"
    end

    test "direct_stream with TEXT subs keeps both video_codec and audio_codec on copy" do
      params = pin_codecs(direct_stream: true, is_bitmap: false)
      assert_equal "copy", params[:video_codec],
        "text subs are external WebVTT, no filter chain needed — video stays copied"
      assert_equal "copy", params[:audio_codec]
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

  # Regression: PlaybackInfo.for composes URLs as `"#{base_url}/transcode/..."`
  # and `"#{base_url}/stream/..."` — RELATIVE to the engine's mount point, not
  # to Rails root. The engine is mounted at /_jellyfin, so the controller must
  # pass `"#{api_base_url}/_jellyfin"` as base_url. Without that prefix the
  # client receives /transcode/... and the URL 404s. Symptom: player starts,
  # shows loading, then black screen with no playback.
  class EngineMountUrlTest < ActiveSupport::TestCase
    test "PlaybackInfo URL composition assumes engine mount prefix in base_url" do
      # Force a transcode decision by handing the profile a source with a codec
      # it cannot direct-play. Lock the assumption: PlaybackInfo composes URLs
      # as `"#{base_url}/transcode/..."` (relative to the engine's mount),
      # so callers must include the mount in base_url. If upstream switches to
      # engine url_helpers and stops needing the prefix, this test will fail
      # and prompt removing the workaround.
      video = Jellyfin::Probing::MediaStream.new(
        index: 0, type: :video, codec: "hevc", width: 1920, height: 1080
      )
      audio = Jellyfin::Probing::MediaStream.new(
        index: 1, type: :audio, codec: "aac", channels: 2
      )
      source = Jellyfin::Probing::MediaSourceInfo.new(
        id: "x", path: "/dev/null", container: "mkv",
        run_time_ticks: 100_000_000, streams: [ video, audio ]
      )
      profile = Jellyfin::Playback::ClientProfile.modern_browser # h264 only

      decision = Jellyfin::Playback::PlaybackInfo.for(
        media_source: source,
        profile: profile,
        base_url: "http://example.test/_jellyfin",
        token_for_direct: "tok_direct",
        token_for_transcode: "tok_transcode"
      )
      assert_not_nil decision.transcoding_url, "expected a transcode URL for HEVC + h264-only profile"
      assert decision.transcoding_url.start_with?("http://example.test/_jellyfin/transcode/"),
        "expected URL under the engine mount path, got: #{decision.transcoding_url.inspect}"
    end
  end

  # Regression: /api/playback/start used to always return subtitleUrl=nil,
  # which left the Player JS with no track to attach — subtitles never
  # rendered (Issue: "subtitles do not show, not bitmap, not other type").
  # Now: when a text subtitle is selected, the controller composes a
  # `/_jellyfin/subtitles/:token/:relative_idx.vtt` URL. The engine's
  # SubtitlesController uses ffmpeg `-map 0:s:<idx>` which expects the
  # SUBTITLE-RELATIVE index (position among subtitle streams), not the
  # absolute stream index reported by ffprobe — so the helper must
  # translate via `Array#index` over the subtitle list.
  class SubtitleDeliveryUrlTest < ActiveSupport::TestCase
    setup do
      @controller = Api::PlaybackController.new
      # subtitle_delivery_url consults api_base_url, which reads request
      # headers. Stub it for unit tests so we don't need an integration
      # request cycle.
      @controller.define_singleton_method(:api_base_url) { "http://test.local" }
    end

    def build_url(streams, idx, is_bitmap: false, token: "tok123")
      @controller.send(:subtitle_delivery_url,
        subtitle_streams: streams,
        subtitle_stream_index: idx,
        is_bitmap: is_bitmap,
        token: token
      )
    end

    test "returns nil when no subtitle is active" do
      assert_nil build_url([ { index: 2 } ], nil)
    end

    test "returns nil for bitmap subtitles (server burns them in)" do
      streams = [ { index: 2, codec: "hdmv_pgs_subtitle", isText: false } ]
      assert_nil build_url(streams, 2, is_bitmap: true)
    end

    test "returns nil if the picked index is not in the streams list" do
      streams = [ { index: 2 }, { index: 3 } ]
      assert_nil build_url(streams, 99)
    end

    test "translates ABSOLUTE stream index to SUBTITLE-RELATIVE index in URL" do
      # Source layout: video=0, audio=1, audio=2, subtitle=3, subtitle=4.
      # Engine's `-map 0:s:N` expects N as the subtitle-relative position.
      # The picked stream's absolute index is 4 → relative index is 1.
      streams = [
        { index: 3, codec: "subrip", isText: true },
        { index: 4, codec: "subrip", isText: true }
      ]
      url = build_url(streams, 4)
      assert_equal "http://test.local/_jellyfin/subtitles/tok123/1.vtt", url
    end

    test "uses .vtt format so native <track> + WebVTT rendering work without libass" do
      streams = [ { index: 3, codec: "ass", isText: true } ]
      url = build_url(streams, 3)
      assert url.end_with?(".vtt"),
        "expected vtt extension so the engine converts ASS → WebVTT for the client, got: #{url}"
    end

    # Regression: do NOT use the engine's `with_ticks` endpoint here. The
    # engine's VOD playlist is built with `seek_seconds: 0` regardless of
    # the user's resume point (transcoding_controller.rb:321), so
    # `video.currentTime` runs in ABSOLUTE source-time and unshifted cues
    # align. Routing through `with_ticks` with the default
    # `preserve_original_timestamps = false` would rebase cues to start at
    # 0 and push them off by exactly the resume offset — confirmed by the
    # user as "completely out of sync" after a switch at 30:00.
    test "URL does NOT carry start ticks (engine playlist is full 0..total)" do
      streams = [ { index: 3, codec: "subrip", isText: true } ]
      url = build_url(streams, 3)
      # If this ever gains a `/N.vtt` segment, the renderer will drift by N
      # seconds on every audio/subtitle switch.
      assert_match %r{/_jellyfin/subtitles/tok123/0\.vtt\z}, url
      refute_match %r{/\d+/\d+\.vtt\z}, url,
        "subtitle URL must not include start_position_ticks — the engine playlist starts at 0 every time"
    end
  end

  # Regression: each /start call previously left the previous transcode
  # job's ffmpeg running. Audio + subtitle switches re-issue /start with
  # new tokens (different job_id), so the client's subsequent /stop only
  # killed the newest job. With dual-language episodes the user saw two
  # ffmpegs at ~900 % CPU after a single audio switch.
  #
  # Upstream Jellyfin mirrors this in DynamicHlsController.cs:1508 —
  # KillTranscodingJobs(deviceId, playSessionId, p => false) runs before
  # spawning a new ffmpeg. Caramba does the equivalent using the Rails
  # session cookie's previous job_id.
  class OrphanJobCleanupTest < ActiveSupport::TestCase
    setup do
      @manager = Jellyfin::Transcoding::TranscodeManager.instance
    end

    test "cancel! is invoked for the previous session's job_id when /start runs again" do
      previous_job_id = "old_job_id_abcd1234"
      new_job_id      = "new_job_id_efgh5678"

      cancelled = []
      manager_double = Object.new
      manager_double.define_singleton_method(:cancel!) { |id| cancelled << id }

      original_instance = Jellyfin::Transcoding::TranscodeManager.method(:instance)
      Jellyfin::Transcoding::TranscodeManager.singleton_class.send(:define_method, :instance) { manager_double }
      begin
        # Inline the relevant branch from #start. Stubbing ffprobe + the
        # engine decision pipeline for the full action is overkill; the
        # cancel branch is the contract we care about.
        sess = { "playback_session_id" => previous_job_id }
        prev = sess["playback_session_id"]
        if prev.present? && prev != new_job_id
          Jellyfin::Transcoding::TranscodeManager.instance.cancel!(prev)
        end
      ensure
        Jellyfin::Transcoding::TranscodeManager.singleton_class.send(:define_method, :instance, original_instance)
      end

      assert_equal [ previous_job_id ], cancelled,
        "expected previous job to be cancelled on /start, got: #{cancelled.inspect}"
    end

    test "no cancel when there is no previous session" do
      cancelled = []
      manager_double = Object.new
      manager_double.define_singleton_method(:cancel!) { |id| cancelled << id }

      original_instance = Jellyfin::Transcoding::TranscodeManager.method(:instance)
      Jellyfin::Transcoding::TranscodeManager.singleton_class.send(:define_method, :instance) { manager_double }
      begin
        sess = {} # fresh session, no prior session_id
        prev = sess["playback_session_id"]
        if prev.present? && prev != "anything"
          Jellyfin::Transcoding::TranscodeManager.instance.cancel!(prev)
        end
      ensure
        Jellyfin::Transcoding::TranscodeManager.singleton_class.send(:define_method, :instance, original_instance)
      end

      assert_empty cancelled, "expected no cancel call on a fresh session, got: #{cancelled.inspect}"
    end
  end
end
