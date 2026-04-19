require "test_helper"

class PosterableTest < ActiveSupport::TestCase
  IMAGE_URL = "https://static.tvmaze.com/uploads/images/original/poster.jpg".freeze

  test "download_poster! attaches the resized image" do
    stub_request(:get, IMAGE_URL).to_return(
      status: 200,
      body: FAKE_JPEG,
      headers: { "Content-Type" => "image/jpeg" }
    )

    show = shows(:breaking_bad)
    show.update!(poster_url: IMAGE_URL)
    show.poster.detach

    assert show.download_poster!
    assert show.poster.attached?
    assert_equal "image/jpeg", show.poster.content_type
    assert_equal "poster.jpg", show.poster.filename.to_s
  end

  test "download_poster! returns false when poster_url is blank" do
    show = shows(:breaking_bad)
    show.update!(poster_url: nil)
    assert_not show.download_poster!
    assert_not show.poster.attached?
  end

  test "download_poster! returns false on upstream error without raising" do
    stub_request(:get, IMAGE_URL).to_return(status: 404)
    show = shows(:breaking_bad)
    show.update!(poster_url: IMAGE_URL)
    show.poster.detach

    assert_not show.download_poster!
    assert_not show.poster.attached?
  end

  test "download_poster! ignores non-http schemes" do
    show = shows(:breaking_bad)
    show.update_columns(poster_url: "file:///etc/passwd")

    assert_not show.download_poster!
    assert_not show.poster.attached?
  end
end
