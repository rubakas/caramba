Rails.application.routes.draw do
  root 'seasons#index'

  post 'episodes/:id/play', to: 'episodes#play', as: :play_episode
  post 'episodes/:id/toggle', to: 'episodes#toggle_watched', as: :toggle_episode
  post 'episodes/scan', to: 'episodes#scan', as: :scan_episodes

  get 'playback/status', to: 'playback#status', as: :playback_status
  get 'history', to: 'history#index', as: :history

  get 'up' => 'rails/health#show', as: :rails_health_check
end
