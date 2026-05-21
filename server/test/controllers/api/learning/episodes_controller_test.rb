require "test_helper"

class Api::Learning::EpisodesControllerTest < ActionDispatch::IntegrationTest
  setup do
    # Wipe existing fixture tech_metadata so we only see what we set here.
    Episode.update_all(tech_metadata: nil)
  end

  test "lists episodes with a text subtitle stream" do
    ep = episodes(:bb_s01e01)
    ep.update_column(:tech_metadata, {
      "subtitleStreams" => [
        { "index" => 2, "codec" => "subrip", "language" => "eng", "isText" => true }
      ]
    }.to_json)

    get "/api/learning/episodes"
    assert_response :success
    body = JSON.parse(response.body)
    ids = body.map { |e| e["id"] }
    assert_includes ids, ep.id
  end

  test "excludes episodes without subtitle streams" do
    ep = episodes(:bb_s01e02)
    ep.update_column(:tech_metadata, { "subtitleStreams" => [] }.to_json)
    get "/api/learning/episodes"
    body = JSON.parse(response.body)
    assert_not_includes body.map { |e| e["id"] }, ep.id
  end

  test "excludes episodes whose only subtitle stream is bitmap (PGS)" do
    ep = episodes(:bb_s01e01)
    ep.update_column(:tech_metadata, {
      "subtitleStreams" => [
        { "index" => 2, "codec" => "hdmv_pgs_subtitle", "language" => "eng", "isText" => false }
      ]
    }.to_json)
    get "/api/learning/episodes"
    body = JSON.parse(response.body)
    assert_not_includes body.map { |e| e["id"] }, ep.id
  end

  test "exposes extracted subtitle on the episode row when present" do
    ep = episodes(:bb_s01e01)
    ep.update_column(:tech_metadata, {
      "subtitleStreams" => [
        { "index" => 2, "codec" => "subrip", "language" => "eng", "isText" => true }
      ]
    }.to_json)
    LearningSubtitle.create!(
      media: ep, stream_index: 2, language: "eng", format: "srt",
      path: "/tmp/x.srt", byte_size: 1234, extracted_at: Time.current
    )

    get "/api/learning/episodes"
    row = JSON.parse(response.body).find { |e| e["id"] == ep.id }
    assert_not_nil row["subtitle"]
    assert_equal "eng", row["subtitle"]["language"]
    assert_equal "srt", row["subtitle"]["format"]
    assert_equal 1234, row["subtitle"]["byteSize"]
  end

  test "response shape uses camelCase" do
    ep = episodes(:bb_s01e01)
    ep.update_column(:tech_metadata, {
      "subtitleStreams" => [
        { "index" => 2, "codec" => "subrip", "language" => "eng", "isText" => true }
      ]
    }.to_json)

    get "/api/learning/episodes"
    row = JSON.parse(response.body).find { |e| e["id"] == ep.id }
    %w[showId showName seasonNumber episodeNumber lastWatchedAt].each do |key|
      assert row.key?(key), "expected key #{key} in #{row.inspect}"
    end
  end
end
