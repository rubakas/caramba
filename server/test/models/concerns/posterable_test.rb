require "test_helper"

class PosterableTest < ActiveSupport::TestCase
  IMAGE_URL = "https://static.tvmaze.com/uploads/images/original/poster.jpg".freeze

  test "download_poster! attaches the fetched image" do
    stub_request(:get, IMAGE_URL).to_return(
      status: 200,
      body: "\xFF\xD8\xFFbytes".b,
      headers: { "Content-Type" => "image/jpeg" }
    )

    series = series(:breaking_bad)
    series.update!(poster_url: IMAGE_URL)
    series.poster.detach

    assert series.download_poster!
    assert series.poster.attached?
    assert_equal "image/jpeg", series.poster.content_type
    assert_equal "poster.jpg", series.poster.filename.to_s
  end

  test "download_poster! returns false when poster_url is blank" do
    series = series(:breaking_bad)
    series.update!(poster_url: nil)
    assert_not series.download_poster!
    assert_not series.poster.attached?
  end

  test "download_poster! returns false on upstream error without raising" do
    stub_request(:get, IMAGE_URL).to_return(status: 404)
    series = series(:breaking_bad)
    series.update!(poster_url: IMAGE_URL)
    series.poster.detach

    assert_not series.download_poster!
    assert_not series.poster.attached?
  end

  test "download_poster! ignores non-http schemes" do
    series = series(:breaking_bad)
    series.update_columns(poster_url: "file:///etc/passwd")

    assert_not series.download_poster!
    assert_not series.poster.attached?
  end
end
