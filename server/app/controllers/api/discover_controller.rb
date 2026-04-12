class Api::DiscoverController < Api::BaseController
  # GET /api/discover/search?q=breaking+bad&type=all
  def search
    query = params[:q]&.strip
    return render(json: { shows: [], movies: [] }) if query.blank? || query.length < 2

    search_type = params[:type] || "all"

    # Fire requests in parallel using threads
    shows_thread = nil
    movies_thread = nil

    if search_type.in?(%w[all shows])
      shows_thread = Thread.new { TvmazeService.search_shows(query) }
    end

    if search_type.in?(%w[all movies])
      movies_thread = Thread.new { ImdbApiService.search_titles(query) }
    end

    raw_shows = shows_thread&.value || []
    raw_movies = movies_thread&.value || []

    # Annotate shows with in_library / in_watchlist flags
    slug_by_tvmaze = Series.where.not(tvmaze_id: nil).pluck(:tvmaze_id, :slug).to_h
    watchlist_tvmaze_ids = Watchlist.where.not(tvmaze_id: nil).where(type: "show").pluck(:tvmaze_id).to_set

    shows = raw_shows.map do |show|
      show.merge(
        "in_library" => slug_by_tvmaze.key?(show["tvmaze_id"]),
        "library_slug" => slug_by_tvmaze[show["tvmaze_id"]],
        "in_watchlist" => watchlist_tvmaze_ids.include?(show["tvmaze_id"])
      )
    end

    # Annotate movies
    slug_by_imdb = Movie.where.not(imdb_id: nil).pluck(:imdb_id, :slug).to_h
    watchlist_imdb_ids = Watchlist.where.not(imdb_id: nil).where(type: "movie").pluck(:imdb_id).to_set

    movies = raw_movies.map do |movie|
      movie.merge(
        "in_library" => slug_by_imdb.key?(movie["imdb_id"]),
        "library_slug" => slug_by_imdb[movie["imdb_id"]],
        "in_watchlist" => watchlist_imdb_ids.include?(movie["imdb_id"])
      )
    end

    render json: { shows: shows, movies: movies }
  end

  # GET /api/discover/show_details?tvmaze_id=123
  def show_details
    return render(json: nil) unless params[:tvmaze_id].present?
    render json: TvmazeService.show_details(params[:tvmaze_id])
  end

  # GET /api/discover/movie_details?imdb_id=tt1234567
  def movie_details
    return render(json: nil) unless params[:imdb_id].present?
    render json: ImdbApiService.title_details(params[:imdb_id])
  end
end
