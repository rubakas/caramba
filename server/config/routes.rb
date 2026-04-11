Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  namespace :api do
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
      end
    end

    resources :movies, param: :slug do
      member do
        post :toggle
        post :refresh_metadata
      end
    end

    resource :playback, only: [], controller: :playback do
      post :report_progress
      get :preferences
      post :preferences, action: :save_preferences, as: :save_preferences
    end

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
end
