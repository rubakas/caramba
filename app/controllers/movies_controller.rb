class MoviesController < ApplicationController
  before_action :set_movie, only: %i[show play toggle refresh_metadata destroy]

  def index
    @movies = Movie.by_title
  end

  def new; end

  def show; end

  def create
    file_paths = params[:file_paths]&.reject(&:blank?)

    if file_paths.blank?
      redirect_to new_movie_path, alert: 'No files selected.'
      return
    end

    added = 0
    file_paths.each do |path|
      path = path.strip
      next unless File.exist?(path)
      next if Movie.exists?(file_path: path)

      title = Movie.name_from_filename(path)
      year  = Movie.year_from_filename(File.basename(path))

      movie = Movie.create!(
        title: title,
        file_path: path,
        year: year
      )

      MovieMetadataFetcher.fetch!(movie)
      added += 1
    end

    if added > 0
      redirect_to movies_path, notice: "Added #{added} movie#{'s' if added > 1}."
    else
      redirect_to new_movie_path, alert: 'No new movies were added. Files may already exist in library.'
    end
  end

  def play
    @movie.mark_watched!

    start_time = @movie.in_progress? ? @movie.progress_seconds : nil
    VlcPlayer.play(@movie.file_path, start_time: start_time)

    session[:current_movie_id] = @movie.id
    session.delete(:current_episode_id)
    session.delete(:current_history_id)
    session.delete(:current_series_slug)

    redirect_to movie_path(@movie.slug), notice: "Playing #{@movie.title}"
  end

  def toggle
    if @movie.watched?
      @movie.mark_unwatched!
    else
      @movie.mark_watched!
    end

    redirect_to movie_path(@movie.slug)
  end

  def refresh_metadata
    MovieMetadataFetcher.fetch!(@movie)
    redirect_to movie_path(@movie.slug), notice: 'Metadata refreshed.'
  end

  def destroy
    name = @movie.title
    @movie.destroy!
    redirect_to movies_path, notice: "'#{name}' removed."
  end

  private

  def set_movie
    @movie = Movie.find_by!(slug: params[:slug])
  end
end
