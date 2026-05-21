# Extracts every text subtitle stream from an Episode/Movie source file
# into the writable learning sidecar tree, then upserts LearningSubtitle
# rows pointing at the resulting .srt files.
#
# Enqueued by Api::Learning::SubtitlesController#create. Idempotent —
# re-runs reuse existing rows by [media, stream_index] and only re-extract
# if the destination file is missing or empty.

class LearningSubtitleExtractJob < ApplicationJob
  queue_as :default

  discard_on ActiveJob::DeserializationError

  def perform(media)
    return if media.file_path.blank?
    return unless File.exist?(media.file_path)

    source = Jellyfin::MediaEncoder::Probe.from_path(media.file_path)
    return if source.nil?

    text_streams = source.subtitle_streams.select do |s|
      Jellyfin::Subtitle::BulkExtractor::TEXT_CODECS.include?(s.codec.to_s.downcase)
    end
    return if text_streams.empty?

    extracted = Jellyfin::Subtitle::BulkExtractor.new.extract_all(source)
    extracted.each do |entry|
      install_subtitle(media, entry)
    end
  end

  private

  def install_subtitle(media, entry)
    language = entry[:language].to_s.presence || "und"
    format = entry[:format].to_s.presence || "srt"

    destination = LearningArtifactsService.subtitle_path_for(media, language: language, format: format)
    LearningArtifactsService.ensure_dir!(destination)

    needs_copy = !File.exist?(destination) || File.size(destination).zero?
    FileUtils.cp(entry[:path], destination) if needs_copy

    record = LearningSubtitle.find_or_initialize_by(
      media_type: media.class.name,
      media_id: media.id,
      stream_index: entry[:stream_index]
    )
    record.assign_attributes(
      language: language,
      format: format,
      path: destination,
      byte_size: File.size(destination),
      extracted_at: Time.current
    )
    record.save!
  end
end
