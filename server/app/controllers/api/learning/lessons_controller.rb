# Materializes a lesson from a phrase list — the contract Phase 2's manual
# paste flow uses and Phase 4's automated LessonAi will produce. Body shape:
#
#   POST /api/learning/lessons
#   {
#     "episodeId": 42,            # or "movieId"
#     "phrases": [
#       {
#         "phrase":      "I'm Carrie Bradshaw",
#         "translation": "Я Керрі Бредшоу",
#         "meaning":     "Self-introduction; \"I'm\" = \"I am\".",
#         "startMs":     12000,
#         "endMs":       14500
#       }, ...
#     ],
#     "provider": "manual",       # optional, defaults to "manual"
#     "model":    "claude-sonnet-4-6"  # optional
#   }
#
# Clips are NOT generated here — Phase 3 enqueues per-phrase ClipExtractJobs.

class Api::Learning::LessonsController < Api::Learning::BaseController
  class BadRequest < StandardError; end

  def create
    lesson = build_lesson
    Lesson.transaction do
      lesson.save!
      phrases_param.each.with_index(1) do |attrs, position|
        lesson.phrases.create!(
          position:    position,
          phrase:      fetch_required(attrs, "phrase"),
          translation: attrs["translation"],
          meaning:     attrs["meaning"],
          start_ms:    fetch_required(attrs, "startMs").to_i,
          end_ms:      fetch_required(attrs, "endMs").to_i
        )
      end
      lesson.update!(status: "ready")
    end
    render json: serialize(lesson), status: :created
  rescue BadRequest => e
    render json: { error: e.message }, status: :bad_request
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def show
    lesson = Lesson.includes(:phrases, :episode, :movie, :source_subtitle).find(params[:id])
    render json: serialize(lesson)
  end

  private

  def build_lesson
    episode_id = params[:episodeId] || params[:episode_id]
    movie_id   = params[:movieId]   || params[:movie_id]
    raise BadRequest, "episodeId or movieId is required" if episode_id.blank? && movie_id.blank?

    media = if episode_id.present?
              Episode.find(episode_id)
            else
              Movie.find(movie_id)
            end

    source = best_subtitle_for(media) or
      raise BadRequest, "No extracted subtitle for this media — call /api/learning/subtitles first"

    Lesson.new(
      episode: media.is_a?(Episode) ? media : nil,
      movie:   media.is_a?(Movie)   ? media : nil,
      source_subtitle: source,
      status:   "generating",
      provider: params[:provider].presence || "manual",
      model:    params[:model].presence,
      prompt_version: params[:promptVersion].presence&.to_i || 1
    )
  end

  def best_subtitle_for(media)
    subs = media.learning_subtitles.to_a
    subs.find { |s| s.language == "eng" } ||
      subs.find { |s| s.language == "en" } ||
      subs.first
  end

  def phrases_param
    list = params[:phrases]
    raise BadRequest, "phrases must be a non-empty array" unless list.is_a?(Array) && list.any?
    list.map { |p| p.respond_to?(:to_unsafe_h) ? p.to_unsafe_h : p.to_h }
  end

  def fetch_required(hash, key)
    value = hash[key.to_s] || hash[key.to_sym]
    raise ArgumentError, "Missing required phrase key: #{key}" if value.nil? || (value.respond_to?(:empty?) && value.empty?)
    value
  end

  def serialize(lesson)
    {
      id: lesson.id,
      status: lesson.status,
      error: lesson.error,
      provider: lesson.provider,
      model: lesson.model,
      promptVersion: lesson.prompt_version,
      targetLanguage: lesson.target_language,
      sourceLanguage: lesson.source_language,
      episodeId: lesson.episode_id,
      movieId: lesson.movie_id,
      sourceSubtitleId: lesson.source_subtitle_id,
      phrases: lesson.phrases.map { |p| serialize_phrase(p) },
      createdAt: lesson.created_at,
      updatedAt: lesson.updated_at
    }
  end

  def serialize_phrase(p)
    {
      id: p.id,
      position: p.position,
      phrase: p.phrase,
      translation: p.translation,
      meaning: p.meaning,
      startMs: p.start_ms,
      endMs: p.end_ms,
      clipStatus: p.clip_status,
      clipUrl: nil # Phase 3 fills this in via phrase_clip_url helper.
    }
  end
end
