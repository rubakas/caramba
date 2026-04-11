/**
 * HTTP adapter — calls Rails API via fetch.
 * Used by web app and desktop in server mode.
 */
export function createHttpAdapter(baseUrl = 'http://localhost:3000') {
  const base = baseUrl.replace(/\/+$/, '')

  async function request(path, opts = {}) {
    const url = `${base}${path}`
    const config = { ...opts }
    if (config.body && typeof config.body === 'object') {
      config.headers = { 'Content-Type': 'application/json', ...config.headers }
      config.body = JSON.stringify(config.body)
    }
    const res = await fetch(url, config)
    if (!res.ok) {
      const text = await res.text().catch(() => '')
      throw new Error(`API ${res.status}: ${text}`)
    }
    const contentType = res.headers.get('content-type')
    if (contentType && contentType.includes('application/json')) {
      return res.json()
    }
    return null
  }

  function get(path) { return request(path) }
  function post(path, body) { return request(path, { method: 'POST', body }) }
  function del(path) { return request(path, { method: 'DELETE' }) }

  const noop = () => {}
  const noopAsync = async () => null
  const noopUnsub = () => noop

  return {
    // Series
    listSeries: () => get('/api/series'),
    getResumable: (slug) => get(`/api/series/${slug}/resumable`),
    getSeriesShow: (slug) => get(`/api/series/${slug}/full`),
    addSeries: noopAsync,
    scanSeries: noopAsync,
    refreshSeriesMetadata: noopAsync,
    destroySeries: noopAsync,
    relocateSeries: noopAsync,

    // Episodes
    toggleEpisode: (id) => post(`/api/episodes/${id}/toggle`),
    getNextEpisode: (id) => get(`/api/episodes/${id}/next`),
    playEpisode: noopAsync,

    // Movies
    listMovies: () => get('/api/movies'),
    getMovie: (slug) => get(`/api/movies/${slug}`),
    addMovies: noopAsync,
    toggleMovie: (slug) => post(`/api/movies/${slug}/toggle`),
    refreshMovieMetadata: noopAsync,
    destroyMovie: noopAsync,
    relocateMovie: noopAsync,
    playMovie: noopAsync,

    // Playback — all no-ops for web
    startPlayback: noopAsync,
    stopPlayback: noopAsync,
    setPlaybackEpisode: noopAsync,
    setPlaybackMovie: noopAsync,
    seekPlayback: noopAsync,
    reportProgress: noopAsync,
    getPlaybackStatus: noopAsync,
    getPlaybackPreferences: noopAsync,
    savePlaybackPreferences: noopAsync,
    switchAudio: noopAsync,
    switchSubtitle: noopAsync,
    switchBitmapSubtitle: noopAsync,

    // VLC — no-ops
    checkVlc: async () => false,
    openInVlc: noopAsync,
    openInDefault: noopAsync,

    // Downloads — no-ops
    downloadEpisode: noopAsync,
    deleteDownloadEpisode: noopAsync,
    downloadSeason: noopAsync,
    deleteDownloadSeason: noopAsync,
    downloadMovie: noopAsync,
    deleteDownloadMovie: noopAsync,

    // Discover
    searchShows: (query, type) => get(`/api/discover/search?q=${encodeURIComponent(query)}&type=${encodeURIComponent(type || 'all')}`),
    getShowDetails: (tvmazeId) => get(`/api/discover/show_details?tvmaze_id=${encodeURIComponent(tvmazeId)}`),
    getMovieDetails: (imdbId) => get(`/api/discover/movie_details?imdb_id=${encodeURIComponent(imdbId)}`),

    // Watchlist
    listWatchlist: () => get('/api/watchlist'),
    addToWatchlist: (item) => post('/api/watchlist', { watchlist: item }),
    removeFromWatchlist: (identifier) => {
      // identifier can be a tvmaze_id (number) or { _type: 'movie', imdb_id }
      if (typeof identifier === 'object' && identifier._type === 'movie') {
        return del(`/api/watchlist/${encodeURIComponent(identifier.imdb_id)}?type=movie`)
      }
      return del(`/api/watchlist/${encodeURIComponent(identifier)}`)
    },

    // History
    listHistory: (limit) => get(`/api/history${limit ? `?limit=${limit}` : ''}`),
    getHistoryStats: () => get('/api/history/stats'),

    // Settings — no-ops
    getSettings: noopAsync,
    setSyncFolder: noopAsync,
    syncNow: noopAsync,
    loadFromSync: noopAsync,

    // File pickers — no-ops
    selectFolder: noopAsync,
    selectFiles: noopAsync,

    // Events — no-op subscribers
    onVlcPlaybackEnded: noopUnsub,
    onMediaDownloadProgress: noopUnsub,
    onSubtitlesReady: noopUnsub,

    // Updates — no-ops
    checkForUpdate: noopAsync,
    onUpdateAvailable: noopUnsub,
    onDownloadProgress: noopUnsub,
    downloadUpdate: noopAsync,
    installUpdate: noopAsync,
  }
}

/** Default capabilities for web / HTTP mode */
export const httpCapabilities = {
  canPlay: false,
  canDownload: false,
  canAdd: false,
  canManage: false,
  canOpenExternal: false,
  hasNowPlaying: false,
  hasSettings: false,
}
