require "test_helper"

class LearningArtifactsServiceTest < ActiveSupport::TestCase
  setup do
    @learning_root = Dir.mktmpdir
    @prev_root = Rails.configuration.x.learning.root
    Rails.configuration.x.learning.root = @learning_root
  end

  teardown do
    Rails.configuration.x.learning.root = @prev_root
    FileUtils.remove_entry(@learning_root) if @learning_root && File.exist?(@learning_root)
  end

  test "subtitle_path_for mirrors episode file_path under learning root" do
    Dir.mktmpdir do |media_root|
      shows_dir = File.join(media_root, "shows")
      FileUtils.mkdir_p(shows_dir)
      MediaFolder.create!(path: shows_dir, kind: "shows", enabled: true)
      show = Show.create!(name: "Demo", media_path: File.join(shows_dir, "Demo (2020)"))
      ep = Episode.create!(
        show: show, code: "S01E01", title: "Pilot",
        season_number: 1, episode_number: 1,
        file_path: File.join(shows_dir, "Demo (2020)", "Season 01", "Demo - S01E01.mkv")
      )

      path = LearningArtifactsService.subtitle_path_for(ep, language: "eng", format: "srt")
      expected = File.join(@learning_root, "shows", "Demo (2020)", "Season 01", "Demo - S01E01.eng.srt")
      assert_equal expected, path
    end
  end

  test "extension swap handles compound paths correctly" do
    Dir.mktmpdir do |media_root|
      shows_dir = File.join(media_root, "shows")
      FileUtils.mkdir_p(shows_dir)
      MediaFolder.create!(path: shows_dir, kind: "shows", enabled: true)
      show = Show.create!(name: "X", media_path: File.join(shows_dir, "X"))
      ep = Episode.create!(
        show: show, code: "S01E01", title: "T",
        season_number: 1, episode_number: 1,
        file_path: File.join(shows_dir, "X", "show.s01e01.mkv")
      )
      path = LearningArtifactsService.subtitle_path_for(ep)
      assert path.end_with?(".eng.srt"), path
      assert_not_includes path, ".mkv"
    end
  end

  test "falls back to orphan/ when no MediaFolder matches" do
    ep = Episode.new
    ep.file_path = "/some/wild/path/movie.mkv"
    path = LearningArtifactsService.subtitle_path_for(ep)
    assert_equal File.join(@learning_root, "orphan", "movie.eng.srt"), path
  end

  test "ensure_dir! creates parent directories" do
    target = File.join(@learning_root, "deep", "nested", "file.srt")
    assert_not File.exist?(File.dirname(target))
    LearningArtifactsService.ensure_dir!(target)
    assert File.directory?(File.dirname(target))
  end

  test "raises on blank file_path" do
    ep = Episode.new(file_path: nil)
    assert_raises(ArgumentError) { LearningArtifactsService.subtitle_path_for(ep) }
  end
end
