require "test_helper"

class Api::Learning::LessonsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @episode = episodes(:bb_s01e01)
    @sub = LearningSubtitle.create!(
      media: @episode, stream_index: 2, language: "eng", format: "srt",
      path: "/tmp/x.srt", byte_size: 100, extracted_at: Time.current
    )
  end

  test "create persists lesson + phrases and returns ready status" do
    payload = {
      episodeId: @episode.id,
      phrases: [
        { phrase: "Hello world",       translation: "Привіт",  meaning: "Greeting",       startMs: 1000, endMs: 2500 },
        { phrase: "How are you today", translation: "Як ти?",  meaning: "Casual ask",     startMs: 3000, endMs: 5000 }
      ]
    }
    post "/api/learning/lessons", params: payload, as: :json

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "ready", body["status"]
    assert_equal "manual", body["provider"]
    assert_equal @episode.id, body["episodeId"]
    assert_equal 2, body["phrases"].size
    assert_equal [ 1, 2 ], body["phrases"].map { |p| p["position"] }

    lesson = Lesson.find(body["id"])
    assert_equal @episode, lesson.episode
    assert_equal @sub,     lesson.source_subtitle
    assert_equal 2, lesson.phrases.count
  end

  test "create wraps phrase inserts in a transaction" do
    payload = {
      episodeId: @episode.id,
      phrases: [
        { phrase: "ok", translation: "ok", meaning: "ok", startMs: 1000, endMs: 2000 },
        # Second entry is invalid: end_ms <= start_ms — should rollback everything.
        { phrase: "bad", translation: "x", meaning: "y", startMs: 5000, endMs: 5000 }
      ]
    }
    assert_no_difference [ "Lesson.count", "Phrase.count" ] do
      post "/api/learning/lessons", params: payload, as: :json
    end
    assert_response :unprocessable_entity
  end

  test "create errors when phrases array missing" do
    post "/api/learning/lessons", params: { episodeId: @episode.id }, as: :json
    assert_response :bad_request
  end

  test "create errors when neither episodeId nor movieId is given" do
    post "/api/learning/lessons", params: { phrases: [ { phrase: "x", startMs: 0, endMs: 1 } ] }, as: :json
    assert_response :bad_request
  end

  test "create errors when phrase entries are missing required keys" do
    payload = { episodeId: @episode.id, phrases: [ { phrase: "x", startMs: 0 } ] }
    post "/api/learning/lessons", params: payload, as: :json
    assert_response :unprocessable_entity
    assert_match(/endMs/i, response.body)
  end

  test "show returns lesson with phrases in camelCase" do
    lesson = Lesson.create!(episode: @episode, source_subtitle: @sub, status: "ready")
    Phrase.create!(lesson: lesson, position: 1, phrase: "Hi", translation: "Привіт",
                   meaning: "Greeting", start_ms: 1000, end_ms: 2000)

    get "/api/learning/lessons/#{lesson.id}"
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal lesson.id, body["id"]
    assert_equal "ready",   body["status"]
    assert_equal 1, body["phrases"].size
    assert body["phrases"][0].key?("startMs")
    assert body["phrases"][0].key?("clipStatus")
    assert_nil body["phrases"][0]["clipUrl"]
  end

  test "show 404s for unknown lesson" do
    get "/api/learning/lessons/999999"
    assert_response :not_found
  end
end
