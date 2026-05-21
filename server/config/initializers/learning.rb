# Root directory for learning-mode sidecar artifacts (extracted subtitles,
# generated clips). Mirrored from the media tree at this path so a file at
# `/media/shows/X/S01E01.mkv` has its artifacts at `/learning/shows/X/S01E01.eng.srt`.
#
# The production docker-compose mounts a writable host directory here while
# `/media` itself stays read-only — see deploy/docker-compose.yml.
Rails.application.config.x.learning.root =
  ENV.fetch("LEARNING_PATH", Rails.root.join("tmp/learning").to_s)
