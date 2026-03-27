class SeasonsController < ApplicationController
  def index
    @seasons = Episode.grouped_by_season
    @last_watched = Episode.last_watched
    @next_episode = Episode.next_episode
    @resume_episode = Episode.resumable
  end
end
