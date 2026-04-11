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
