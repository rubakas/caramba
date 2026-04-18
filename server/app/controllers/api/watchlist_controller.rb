class Api::WatchlistController < Api::BaseController
  # GET /api/watchlist
  def index
    items = Watchlist.order(created_at: :desc)

    library_series = Series.where.not(tvmaze_id: nil).pluck(:tvmaze_id, :slug)
    slug_by_tvmaze = library_series.to_h

    library_movies = Movie.where.not(imdb_id: nil).pluck(:imdb_id, :slug)
    slug_by_imdb = library_movies.to_h

    render json: items.with_attached_poster.map { |item|
      is_movie = item.type == "movie"
      item.as_json.merge(
        "_type" => item.type || "show",
        "poster_url" => poster_url_for(item),
        "in_library" => is_movie ? slug_by_imdb.key?(item.imdb_id) : slug_by_tvmaze.key?(item.tvmaze_id),
        "library_slug" => is_movie ? slug_by_imdb[item.imdb_id] : slug_by_tvmaze[item.tvmaze_id],
        "in_watchlist" => true
      )
    }
  end

  # POST /api/watchlist
  # Body: { _type: "show"|"movie", tvmaze_id, imdb_id, name, poster_url, ... }
  def create
    if params[:_type] == "movie"
      return render(json: { error: "Missing imdb_id" }, status: :unprocessable_entity) unless params[:imdb_id].present?

      item = Watchlist.find_by(imdb_id: params[:imdb_id]) || Watchlist.create!(
        type: "movie",
        imdb_id: params[:imdb_id],
        name: params[:name],
        poster_url: params[:poster_url],
        description: params[:description],
        genres: params[:genres],
        rating: params[:rating],
        year: params[:year],
        director: params[:director],
        runtime: params[:runtime]
      )
    else
      return render(json: { error: "Missing tvmaze_id" }, status: :unprocessable_entity) unless params[:tvmaze_id].present?

      item = Watchlist.find_by(tvmaze_id: params[:tvmaze_id]) || Watchlist.create!(
        type: "show",
        tvmaze_id: params[:tvmaze_id],
        name: params[:name],
        poster_url: params[:poster_url],
        description: params[:description],
        genres: params[:genres],
        rating: params[:rating],
        premiered: params[:premiered],
        status: params[:status],
        network: params[:network],
        imdb_id: params[:imdb_id]
      )
    end

    item.download_poster! unless item.poster.attached?

    render json: { success: true }
  end

  # DELETE /api/watchlist/:id
  # Accepts id, or query params ?tvmaze_id= or ?imdb_id=
  def destroy
    if params[:tvmaze_id].present?
      Watchlist.where(tvmaze_id: params[:tvmaze_id]).destroy_all
    elsif params[:imdb_id].present?
      Watchlist.where(imdb_id: params[:imdb_id]).destroy_all
    else
      Watchlist.find(params[:id]).destroy!
    end
    render json: { success: true }
  end
end
