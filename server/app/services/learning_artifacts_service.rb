# Maps media file paths to learning-mode sidecar artifact paths.
#
# A subtitle for the episode at
#   /media/shows/Sex and the City (1998)/Season 01/S01E01.mkv
# lives at
#   /learning/shows/Sex and the City (1998)/Season 01/S01E01.eng.srt
#
# The media tree mounts read-only at /media; the learning tree mirrors it
# under a writable root configured via Rails.configuration.x.learning.root
# (LEARNING_PATH env var in production).

class LearningArtifactsService
  class << self
    def subtitle_path_for(media, language: "eng", format: "srt")
      build_artifact_path(media.file_path, ".#{language}.#{format}")
    end

    def clip_path_for(phrase)
      media = phrase.lesson.episode || phrase.lesson.movie
      build_artifact_path(media.file_path, ".phrase-#{format("%02d", phrase.position)}.mp4")
    end

    def ensure_dir!(path)
      FileUtils.mkdir_p(File.dirname(path))
      path
    end

    def root
      Rails.configuration.x.learning.root
    end

    private

    def build_artifact_path(file_path, suffix)
      raise ArgumentError, "file_path required" if file_path.blank?
      mirrored = mirror_under_root(file_path)
      base_without_ext = mirrored.sub(/\.[^.\/]+\z/, "")
      "#{base_without_ext}#{suffix}"
    end

    # Strip the matching MediaFolder.path prefix from file_path and re-root
    # under <learning_root>/<folder.kind>/. Falls back to <learning_root>/orphan/<basename>
    # if no folder matches (shouldn't happen in normal flow).
    def mirror_under_root(file_path)
      folder = MediaFolder.all.find { |f| f.path.present? && file_path.start_with?(ensure_trailing_slash(f.path)) }
      if folder
        relative = file_path.sub(/\A#{Regexp.escape(ensure_trailing_slash(folder.path))}/, "")
        File.join(root, folder.kind, relative)
      else
        File.join(root, "orphan", File.basename(file_path))
      end
    end

    def ensure_trailing_slash(path)
      path.end_with?("/") ? path : "#{path}/"
    end
  end
end
