# Lists episodes eligible for lesson generation: those whose tech_metadata
# advertises at least one text subtitle stream. Bitmap-only sources (PGS,
# DVD) are filtered out since text extraction can't recover them.

class Api::Learning::EpisodesController < Api::Learning::BaseController
  def index
    scope = Episode
      .where.not(file_path: nil)
      .includes(:show, :learning_subtitles, lessons: :phrases)
      .order(watched: :desc, last_watched_at: :desc, season_number: :asc, episode_number: :asc)

    payload = []
    scope.find_each(batch_size: 200) do |ep|
      next unless eligible?(ep)
      payload << serialize(ep)
    end

    render json: payload
  end

  private

  def eligible?(episode)
    streams = subtitle_streams(episode)
    return false if streams.empty?
    streams.any? { |s| text_stream?(s) }
  end

  def subtitle_streams(episode)
    raw = episode.tech_metadata
    return [] if raw.blank?
    JSON.parse(raw).fetch("subtitleStreams", []) || []
  rescue JSON::ParserError
    []
  end

  TEXT_CODECS = %w[subrip srt ass ssa webvtt mov_text].to_set.freeze

  def text_stream?(stream)
    return true if stream["isText"]
    TEXT_CODECS.include?(stream["codec"].to_s.downcase)
  end

  def serialize(ep)
    eng_sub = ep.learning_subtitles.find { |s| s.language == "eng" || s.language == "en" }
    {
      id: ep.id,
      showId: ep.show_id,
      showName: ep.show.name,
      code: ep.code,
      seasonNumber: ep.season_number,
      episodeNumber: ep.episode_number,
      title: ep.title,
      watched: ep.watched.to_i == 1,
      lastWatchedAt: ep.last_watched_at,
      subtitle: eng_sub && {
        id: eng_sub.id,
        language: eng_sub.language,
        format: eng_sub.format,
        byteSize: eng_sub.byte_size,
        extractedAt: eng_sub.extracted_at
      },
      lessons: ep.lessons.sort_by(&:created_at).reverse.map { |l| serialize_lesson(l) }
    }
  end

  def serialize_lesson(lesson)
    {
      id: lesson.id,
      status: lesson.status,
      provider: lesson.provider,
      phraseCount: lesson.phrases.size,
      createdAt: lesson.created_at
    }
  end
end
