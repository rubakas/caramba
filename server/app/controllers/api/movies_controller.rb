class Api::MoviesController < Api::BaseController
  # GET /api/movies
  def index
    render json: Movie.all.order(:title)
  end

  # GET /api/movies/:slug
  def show
    movie = Movie.find_by!(slug: params[:slug])
    dl = Download.find_by(movie_id: movie.id)
    render json: movie.as_json.merge("download" => dl&.as_json)
  end

  # POST /api/movies
  # Server-side equivalent of addMovies — parses filenames, fetches metadata
  def create
    file_paths = params[:file_paths]
    return render(json: { error: "file_paths required" }, status: :unprocessable_entity) unless file_paths.is_a?(Array)

    results = file_paths.filter_map do |fp|
      title = MovieParserService.name_from_filename(fp)
      year = MovieParserService.year_from_filename(fp)
      movie = Movie.find_by(file_path: fp) || Movie.create!(title: title, file_path: fp, year: year)
      ImdbApiService.fetch_for_movie(movie)
      movie.reload
    end

    render json: results, status: :created
  end

  # POST /api/movies/:slug/toggle
  def toggle
    movie = Movie.find_by!(slug: params[:slug])
    if movie.watched?
      movie.mark_unwatched!
    else
      movie.mark_watched!
    end
    render json: movie.reload
  end

  # POST /api/movies/:slug/refresh_metadata
  def refresh_metadata
    movie = Movie.find_by!(slug: params[:slug])
    result = ImdbApiService.fetch_for_movie(movie)
    render json: { success: result }
  end

  # DELETE /api/movies/:slug
  def destroy
    movie = Movie.find_by!(slug: params[:slug])
    dl = Download.find_by(movie_id: movie.id)
    if dl
      begin
        File.delete(dl.file_path) if dl.file_path && File.exist?(dl.file_path)
      rescue SystemCallError
        # ignore
      end
    end
    movie.destroy!
    head :no_content
  end
end
