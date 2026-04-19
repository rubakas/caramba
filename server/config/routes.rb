Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  namespace :api do
    get "health", to: "health#show"

    resources :shows, param: :slug do
      member do
        get :full           # combined show page data
        get :episodes
        get :seasons
        get :continue
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

    # HLS stream: serves playlist, init segment, and media segments
    get "playback/hls/:session_id/playlist.m3u8", to: "playback#hls_playlist", as: :playback_hls_playlist
    get "playback/hls/:session_id/:asset", to: "playback#hls_asset", as: :playback_hls_asset,
        constraints: { asset: /(?:init\.mp4|segment_\d+\.m4s)/ }

    # Media file streaming
    get "media/episodes/:id", to: "media#episode", as: :media_episode
    get "media/movies/:id", to: "media#movie", as: :media_movie

    namespace :admin do
      resources :folders, only: [ :index, :create, :update, :destroy ]
      get "browse", to: "browse#index"
      resources :pending_imports, only: [ :index ] do
        member do
          post :confirm
          post :ignore
          post :research
        end
      end
      post "scan", to: "scans#create"
    end
  end

  # SPA catch-all: serve React index.html for all non-API routes.
  # Must be LAST so /api/*, /up, /rails/* (ActiveStorage) and /assets/* routes take priority.
  get "*path", to: "spa#index", constraints: ->(req) {
    !req.path.start_with?("/api/", "/up", "/rails/", "/assets/")
  }
  root "spa#index"
end
