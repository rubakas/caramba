require "test_helper"
require "sentry/scrubbers"

class Sentry::ScrubbersTest < ActiveSupport::TestCase
  # ── scrub_string ─────────────────────────────────────────────────

  test "collapses absolute POSIX user paths to ~/" do
    assert_equal "~/Movies/*.mkv", Sentry::Scrubbers.scrub_string("/Users/vladyslav/Movies/x.mkv")
    assert_equal "~/*.mp4",         Sentry::Scrubbers.scrub_string("/home/vlad/video.mp4")
  end

  test "strips media filename stems, keeping lowercase extension" do
    assert_equal "Failed to transcode *.mkv", Sentry::Scrubbers.scrub_string("Failed to transcode The.Sopranos.S01E03.mkv")
    assert_equal "*.mp4", Sentry::Scrubbers.scrub_string("movie.MP4")
  end

  test "handles usernames with spaces" do
    assert_equal "~/Movies/*.mkv", Sentry::Scrubbers.scrub_string("/Users/Foo Bar/Movies/x.mkv")
  end

  test "redacts TVMaze and IMDb search terms" do
    assert_equal "Failed to fetch TVMaze: <redacted>", Sentry::Scrubbers.scrub_string("Failed to fetch TVMaze: Sopranos")
    assert_equal "Failed to fetch IMDb search: <redacted>", Sentry::Scrubbers.scrub_string("Failed to fetch IMDb search: The Matrix")
  end

  test "leaves non-sensitive strings unchanged" do
    assert_equal "ECONNREFUSED 127.0.0.1:3001", Sentry::Scrubbers.scrub_string("ECONNREFUSED 127.0.0.1:3001")
  end

  test "handles non-string input by returning it unchanged" do
    assert_nil Sentry::Scrubbers.scrub_string(nil)
    assert_equal 42, Sentry::Scrubbers.scrub_string(42)
  end

  # ── scrub_url ────────────────────────────────────────────────────

  test "replaces numeric id segments with :id" do
    assert_equal "/api/series/:id/episodes/:id", Sentry::Scrubbers.scrub_url("/api/series/42/episodes/7")
  end

  test "replaces UUID segments with :id" do
    assert_equal "/session/:id/start", Sentry::Scrubbers.scrub_url("/session/3f8e8a41-2b4c-4d5e-9f0a-1b2c3d4e5f6a/start")
  end

  test "strips query strings entirely" do
    assert_equal "/search", Sentry::Scrubbers.scrub_url("/search?q=sopranos&page=2")
  end

  test "preserves non-id path segments" do
    assert_equal "/api/health", Sentry::Scrubbers.scrub_url("/api/health")
  end

  test "handles absolute URLs" do
    assert_equal "http://localhost:3001/api/series/:id", Sentry::Scrubbers.scrub_url("http://localhost:3001/api/series/42?t=1")
  end

  test "returns non-strings unchanged" do
    assert_nil Sentry::Scrubbers.scrub_url(nil)
  end

  # ── before_send ──────────────────────────────────────────────────

  test "before_send scrubs message, exception value, frame filename and abs_path, request url and query_string" do
    event = {
      message: "Failed to transcode /Users/vladyslav/Movies/x.mkv",
      exception: {
        values: [
          {
            value: "Cannot read /Users/vladyslav/a.mkv",
            stacktrace: {
              frames: [
                { filename: "/Users/vladyslav/server/app/services/x.rb",
                  abs_path: "/Users/vladyslav/server/app/services/x.rb" },
              ],
            },
          },
        ],
      },
      request: { url: "http://localhost:3001/api/series/42?t=1", query_string: "t=1&q=sopranos" },
    }
    result = Sentry::Scrubbers.before_send(event)
    assert_equal "Failed to transcode ~/Movies/*.mkv", result[:message]
    assert_equal "Cannot read ~/*.mkv", result[:exception][:values][0][:value]
    assert_equal "~/server/app/services/x.rb", result[:exception][:values][0][:stacktrace][:frames][0][:filename]
    assert_equal "~/server/app/services/x.rb", result[:exception][:values][0][:stacktrace][:frames][0][:abs_path]
    assert_equal "http://localhost:3001/api/series/:id", result[:request][:url]
    assert_equal "", result[:request][:query_string]
  end

  test "before_send deletes user.username but preserves other user fields" do
    event = { user: { username: "vladyslav", id: "1" } }
    result = Sentry::Scrubbers.before_send(event)
    assert_nil result[:user][:username]
    assert_equal "1", result[:user][:id]
  end

  test "before_send tolerates missing fields" do
    assert_equal({}, Sentry::Scrubbers.before_send({}))
  end

  test "before_send returns the same event object (in-place mutation ok)" do
    event = { message: "ok" }
    assert_same event, Sentry::Scrubbers.before_send(event)
  end

  # ── before_breadcrumb ────────────────────────────────────────────

  test "before_breadcrumb scrubs message, url, from, and to" do
    crumb = {
      message: "Navigation to /series/42",
      data: {
        url: "http://localhost:3001/api/series/42?t=1",
        from: "/series/42",
        to: "/series/43/episode/7",
      },
    }
    result = Sentry::Scrubbers.before_breadcrumb(crumb)
    assert_equal "Navigation to /series/:id", result[:message]
    assert_equal "http://localhost:3001/api/series/:id", result[:data][:url]
    assert_equal "/series/:id", result[:data][:from]
    assert_equal "/series/:id/episode/:id", result[:data][:to]
  end

  test "before_breadcrumb tolerates missing data" do
    assert_equal({ message: "x" }, Sentry::Scrubbers.before_breadcrumb({ message: "x" }))
  end
end
