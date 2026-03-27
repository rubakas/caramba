Rails.application.routes.draw do
  root 'series#index'

  resources :series, param: :slug, only: %i[index show new create destroy] do
    post 'scan', on: :member
    post 'refresh_metadata', on: :member

    resources :episodes, only: [] do
      post 'play', on: :member
      post 'toggle', on: :member
    end
  end

  resources :movies, param: :slug, only: %i[index show new create destroy] do
    post 'play', on: :member
    post 'toggle', on: :member
    post 'refresh_metadata', on: :member
  end

  get 'playback/status', to: 'playback#status', as: :playback_status
  get 'history', to: 'history#index', as: :history

  resource :settings, only: %i[show update] do
    post 'sync_now', on: :member
    post 'load_from_sync', on: :member
  end

  get 'up' => 'rails/health#show', as: :rails_health_check
end
