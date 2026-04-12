Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  namespace :api do
    get "health", to: "health#show"

    resources :series, param: :slug do
      member do
        get :full           # combined show page data
        get :episodes
        get :seasons
        get :resumable
        get :next_up
        post :scan
        post :refresh_metadata
      end
    end

    resources :episodes, only: [] do
      member do
        post :toggle
        get :next
        post :play
      end
    end

    resources :movies, param: :slug do
      member do
        post :toggle
        post :refresh_metadata
        post :play
      end
    end

    resource :playback, only: [], controller: :playback do
      post :report_progress
      get :preferences
      post :preferences, action: :save_preferences, as: :save_preferences
      post :start
      post :seek
      post :stop, action: :stop_playback
      get :subtitles
      post :switch_audio
      post :switch_subtitle
      post :switch_bitmap_subtitle
    end

    # Video stream: pipes ffmpeg fMP4 output directly to HTTP response
    get "playback/stream/:session_id", to: "playback#stream", as: :playback_stream

    # HLS stream: serves playlist and segments for Safari/iOS
    get "playback/hls/:session_id/playlist.m3u8", to: "playback#hls_playlist", as: :playback_hls_playlist
    get "playback/hls/:session_id/:segment", to: "playback#hls_segment", as: :playback_hls_segment,
        constraints: { segment: /segment_\d+\.ts/ }

    resources :history, only: [ :index ], controller: :history do
      collection do
        get :stats
      end
    end

    resources :watchlist, only: [ :index, :create, :destroy ]

    resource :discover, only: [], controller: :discover do
      get :search
      get :show_details
      get :movie_details
    end

    # Media file streaming
    get "media/episodes/:id", to: "media#episode", as: :media_episode
    get "media/movies/:id", to: "media#movie", as: :media_movie
  end

  # SPA catch-all: serve React index.html for all non-API routes.
  # Must be LAST so /api/* and /up routes take priority.
  get "*path", to: "spa#index", constraints: ->(req) {
    !req.path.start_with?("/api/", "/up") && !req.path.start_with?("/assets/")
  }
  root "spa#index"
end
