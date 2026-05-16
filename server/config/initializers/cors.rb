Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins "*"
    resource "/api/*",
      headers: :any,
      methods: [ :get, :post, :put, :patch, :delete, :options, :head ]
    # The jellyfin-rails engine serves HLS playlists, fMP4 segments, and
    # WebVTT subtitles from /_jellyfin/*. The Player's <video crossOrigin=
    # "anonymous"> and hls.js's fetch both REQUIRE Access-Control-Allow-
    # Origin on these responses; without it the video element fires
    # MediaError code 4 ("source not supported"). Affects every non-same-
    # origin renderer: Vite dev (:5173 → :3001), packaged Electron
    # (file:// → LAN host), and the web SPA when accessed from a host
    # other than the Rails server.
    resource "/_jellyfin/*",
      headers: :any,
      methods: [ :get, :options, :head ],
      expose: %w[Content-Length Content-Range Date]
  end
end
