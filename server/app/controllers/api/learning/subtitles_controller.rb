# Subtitle extraction control + retrieval for learning mode.
#
# POST /api/learning/subtitles { episodeId: N }
#   → Enqueues LearningSubtitleExtractJob. Returns immediately with the
#     current LearningSubtitle row if one already exists (idempotent),
#     or { status: "queued" } if extraction is in flight.
#
# GET /api/learning/subtitles/:id
#   → Returns the row + the SRT content so the client can prefill the
#     "paste into Claude.ai" textarea.

class Api::Learning::SubtitlesController < Api::Learning::BaseController
  def create
    episode = Episode.find(params.require(:episodeId))
    existing = best_english_subtitle(episode)
    if existing
      render json: serialize(existing)
    else
      LearningSubtitleExtractJob.perform_later(episode)
      render json: { status: "queued", episodeId: episode.id }, status: :accepted
    end
  end

  def show
    sub = LearningSubtitle.find(params[:id])
    render json: serialize(sub, include_content: true)
  end

  private

  def best_english_subtitle(episode)
    subs = episode.learning_subtitles.to_a
    subs.find { |s| s.language == "eng" } ||
      subs.find { |s| s.language == "en" } ||
      subs.first
  end

  def serialize(sub, include_content: false)
    body = {
      id: sub.id,
      mediaType: sub.media_type,
      mediaId: sub.media_id,
      streamIndex: sub.stream_index,
      language: sub.language,
      format: sub.format,
      byteSize: sub.byte_size,
      extractedAt: sub.extracted_at,
      pathExists: File.exist?(sub.path)
    }
    body[:content] = safe_read(sub.path) if include_content
    body
  end

  def safe_read(path)
    return nil unless File.exist?(path)
    File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace)
  end
end
