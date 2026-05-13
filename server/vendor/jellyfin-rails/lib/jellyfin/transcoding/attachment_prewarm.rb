module Jellyfin
  module Transcoding
    # Pre-extracts embedded font attachments before the first segment is
    # rendered. The subtitle burn-in filter needs the fonts to be present in
    # the cache directory at filter-init time; running this synchronously
    # before spawn_ffmpeg ensures the first segment renders with the correct
    # typeface.
    #
    # Mirrors the IAttachmentExtractor.PrepareAttachmentsAsync call upstream
    # makes at the start of every burn-subs job.
    module AttachmentPrewarm
      module_function

      # Pre-extracts attachments synchronously. Returns the fonts directory
      # path (or nil if no fonts were extracted) so the caller can pass it to
      # the subtitles= filter via :fontsdir=.
      def call(job, ffmpeg_path: nil, cache_root: nil)
        return nil unless burning_subs?(job)

        ffmpeg_path ||= Jellyfin::Rails.configuration.ffmpeg_path
        cache_root  ||= Jellyfin::Rails.configuration.resolved_transcode_dir.to_s

        extractor = Jellyfin::Subtitle::AttachmentExtractor.new(
          ffmpeg_path: ffmpeg_path,
          cache_root: cache_root
        )
        attachments = extractor.extract(job.media_source.path) rescue []
        return nil if attachments.nil? || attachments.empty?

        File.dirname(attachments.first.path)
      end

      def burning_subs?(job)
        return false unless job.respond_to?(:burn_subtitles?)
        job.burn_subtitles?
      end
    end
  end
end
