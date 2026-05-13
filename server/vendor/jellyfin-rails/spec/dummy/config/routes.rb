Dummy::Application.routes.draw do
  mount Jellyfin::Rails::Engine => '/jellyfin'
end
