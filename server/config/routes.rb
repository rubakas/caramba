Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  # Mounted internally; clients hit `/api/playback/*` which shims to these.
  mount Jellyfin::Rails::Engine, at: "/_jellyfin"

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
      post :stop, action: :stop_playback
    end

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
          post :rematch
          post :switch_kind
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
