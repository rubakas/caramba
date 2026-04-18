class Api::EpisodesController < Api::BaseController
  # POST /api/episodes/:id/toggle
  def toggle
    ep = Episode.find(params[:id])
    if ep.watched?
      ep.mark_unwatched!
    else
      ep.mark_watched!
    end
    render json: ep.reload
  end

  # POST /api/episodes/:id/play
  # Marks prior episodes watched, creates watch history, returns playback info.
  # Mirrors desktop episodes:play IPC handler.
  def play
    ep = Episode.find(params[:id])
    return render(json: { error: "File not found: #{ep.file_path}" }, status: :unprocessable_entity) unless ep.file_path.present? && File.exist?(ep.file_path)

    # Mark all prior episodes as watched (implied when you skip ahead in a series)
    Episode.mark_prior_watched!(ep.series_id, ep.season_number, ep.episode_number)

    # Create watch history entry
    wh = ep.watch_histories.create!

    render json: {
      episode_id: ep.id,
      series_id: ep.series_id,
      watch_history_id: wh.id,
      file_path: ep.file_path,
      start_time: ep.resume_time
    }
  end

  # GET /api/episodes/:id/next
  def next
    ep = Episode.find(params[:id])
    nxt = ep.next_episode
    if nxt
      render json: nxt.as_json.merge("series_name" => nxt.series.name)
    else
      render json: nil
    end
  end
end
