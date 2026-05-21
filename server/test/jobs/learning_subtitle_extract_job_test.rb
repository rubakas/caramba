require "test_helper"

class LearningSubtitleExtractJobTest < ActiveJob::TestCase
  setup do
    @learning_root = Dir.mktmpdir
    @media_root = Dir.mktmpdir
    Rails.configuration.x.learning.root = @learning_root

    @folder = MediaFolder.create!(path: @media_root, kind: "shows", enabled: true)
    @show = Show.create!(name: "Job Show", media_path: File.join(@media_root, "JS"))
    season_dir = File.join(@media_root, "JS", "Season 01")
    FileUtils.mkdir_p(season_dir)
    @source_path = File.join(season_dir, "JS - S01E01.mkv")
    File.write(@source_path, "fake-mkv-bytes")
    @episode = Episode.create!(
      show: @show, code: "S01E01", title: "T",
      season_number: 1, episode_number: 1, file_path: @source_path
    )
  end

  teardown do
    FileUtils.remove_entry(@learning_root) if @learning_root && File.exist?(@learning_root)
    FileUtils.remove_entry(@media_root)    if @media_root    && File.exist?(@media_root)
  end

  test "extracts each text subtitle stream and persists LearningSubtitle rows" do
    stub_extract([
      fake_extract(index: 2, language: "eng"),
      fake_extract(index: 3, language: "ukr")
    ]) do
      LearningSubtitleExtractJob.perform_now(@episode)
    end

    subs = @episode.learning_subtitles.order(:stream_index)
    assert_equal 2, subs.size
    assert_equal "eng", subs.first.language
    assert_equal "ukr", subs.last.language

    assert File.exist?(subs.first.path), "expected mirrored file at #{subs.first.path}"
    assert subs.first.path.start_with?(@learning_root), subs.first.path
    assert subs.first.path.end_with?(".eng.srt"), subs.first.path
  end

  test "idempotent — re-running does not duplicate rows or stale the mirror" do
    stub_extract([ fake_extract(index: 2, language: "eng") ]) do
      LearningSubtitleExtractJob.perform_now(@episode)
      LearningSubtitleExtractJob.perform_now(@episode)
    end
    assert_equal 1, @episode.learning_subtitles.count
  end

  test "no-ops when the source file is missing" do
    File.delete(@source_path)
    assert_nothing_raised { LearningSubtitleExtractJob.perform_now(@episode) }
    assert_equal 0, @episode.learning_subtitles.count
  end

  test "no-ops when the source has no text subtitle streams" do
    stub_probe(subtitle_streams: [
      fake_stream(index: 2, codec: "hdmv_pgs_subtitle", language: "eng")
    ]) do
      assert_nothing_raised { LearningSubtitleExtractJob.perform_now(@episode) }
      assert_equal 0, @episode.learning_subtitles.count
    end
  end

  private

  def stub_extract(extracted_entries)
    streams = extracted_entries.map { |e| fake_stream(index: e[:stream_index], codec: "subrip", language: e[:language]) }
    fake = Object.new
    fake.define_singleton_method(:extract_all) { |_source| extracted_entries }
    stub_probe(subtitle_streams: streams) do
      with_stubbed_singleton(Jellyfin::Subtitle::BulkExtractor, :new, ->(**_kwargs) { fake }) do
        yield
      end
    end
  end

  def stub_probe(subtitle_streams:)
    source = Struct.new(:path, :subtitle_streams).new(@source_path, subtitle_streams)
    with_stubbed_singleton(Jellyfin::MediaEncoder::Probe, :from_path, ->(_path, **_kwargs) { source }) do
      yield
    end
  end

  def with_stubbed_singleton(klass, name, replacement)
    original = klass.method(name)
    klass.define_singleton_method(name, replacement)
    yield
  ensure
    klass.define_singleton_method(name, original)
  end

  def fake_stream(index:, codec:, language:)
    Struct.new(:index, :codec, :language, :title, :is_default).new(index, codec, language, nil, false)
      .tap { |s| s.define_singleton_method(:subtitle?) { true } }
  end

  def fake_extract(index:, language:, format: "srt")
    src = File.join(Dir.tmpdir, "stub-#{index}.#{format}")
    File.write(src, "1\n00:00:00,000 --> 00:00:02,000\nhello\n\n")
    { stream_index: index, path: src, language: language, format: format }
  end
end
