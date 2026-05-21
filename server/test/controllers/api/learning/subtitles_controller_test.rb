require "test_helper"

class Api::Learning::SubtitlesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @episode = episodes(:bb_s01e01)
    @tmp = Dir.mktmpdir
    @sub_path = File.join(@tmp, "S01E01.eng.srt")
    File.write(@sub_path, "1\n00:00:00,000 --> 00:00:02,000\nhello\n\n")
  end

  teardown do
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  test "create returns existing subtitle row idempotently" do
    sub = LearningSubtitle.create!(
      media: @episode, stream_index: 3, language: "eng", format: "srt",
      path: @sub_path, byte_size: File.size(@sub_path), extracted_at: Time.current
    )

    assert_no_enqueued_jobs do
      post "/api/learning/subtitles", params: { episodeId: @episode.id }, as: :json
    end
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal sub.id, body["id"]
    assert_equal "eng", body["language"]
  end

  test "create enqueues extract job when no subtitle exists yet" do
    assert_enqueued_with(job: LearningSubtitleExtractJob) do
      post "/api/learning/subtitles", params: { episodeId: @episode.id }, as: :json
    end
    assert_response :accepted
    body = JSON.parse(response.body)
    assert_equal "queued", body["status"]
    assert_equal @episode.id, body["episodeId"]
  end

  test "show returns row plus SRT content" do
    sub = LearningSubtitle.create!(
      media: @episode, stream_index: 3, language: "eng", format: "srt",
      path: @sub_path, byte_size: File.size(@sub_path), extracted_at: Time.current
    )
    get "/api/learning/subtitles/#{sub.id}"
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal sub.id, body["id"]
    assert body["content"].start_with?("1\n")
    assert body["pathExists"]
  end

  test "show 404s for unknown subtitle" do
    get "/api/learning/subtitles/999999"
    assert_response :not_found
  end
end
