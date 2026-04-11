class Api::MediaController < Api::BaseController
  # GET /api/media/episodes/:id
  # Streams episode media file with Range support
  def episode
    ep = Episode.find(params[:id])
    stream_file(ep.file_path)
  end

  # GET /api/media/movies/:id
  # Streams movie media file with Range support
  def movie
    movie = Movie.find(params[:id])
    stream_file(movie.file_path)
  end

  private

  def stream_file(file_path)
    unless file_path.present? && File.exist?(file_path)
      return render(json: { error: "File not found" }, status: :not_found)
    end

    # Determine content type from extension
    ext = File.extname(file_path).downcase
    content_type = case ext
    when ".mkv" then "video/x-matroska"
    when ".mp4", ".m4v" then "video/mp4"
    when ".avi" then "video/x-msvideo"
    when ".mov" then "video/quicktime"
    else "application/octet-stream"
    end

    send_file file_path,
      type: content_type,
      disposition: :inline,
      streaming: true
  end
end
