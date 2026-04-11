/**
 * HTTP adapter — calls Rails API via fetch.
 * Used by web app and desktop in server mode.
 */
export function createHttpAdapter(baseUrl = 'http://localhost:3000') {
  const base = baseUrl.replace(/\/+$/, '')

  // Active playback session ID (set by startPlayback, cleared by stopPlayback)
  let activeSessionId = null

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
    playEpisode: (id) => post(`/api/episodes/${id}/play`),

    // Movies
    listMovies: () => get('/api/movies'),
    getMovie: (slug) => get(`/api/movies/${slug}`),
    addMovies: noopAsync,
    toggleMovie: (slug) => post(`/api/movies/${slug}/toggle`),
    refreshMovieMetadata: noopAsync,
    destroyMovie: noopAsync,
    relocateMovie: noopAsync,
    playMovie: (slug) => post(`/api/movies/${slug}/play`),

    // Playback
    startPlayback: async (filePath, startTime, prefs) => {
      const result = await post('/api/playback/start', { filePath, startTime, prefs })
      if (result && result.sessionId) {
        activeSessionId = result.sessionId
      }
      return result
    },
    stopPlayback: async (finalTime, finalDuration) => {
      const sid = activeSessionId
      activeSessionId = null
      if (!sid) return null
      return post('/api/playback/stop', { session: sid })
    },
    setPlaybackEpisode: noopAsync, // folded into server-side session state
    setPlaybackMovie: noopAsync,   // folded into server-side session state
    seekPlayback: async (seekTime) => {
      if (!activeSessionId) return null
      return post('/api/playback/seek', { session: activeSessionId, seekTime })
    },
    reportProgress: async (videoTime, videoDuration) => {
      return post('/api/playback/report_progress', { time: videoTime, duration: videoDuration })
    },
    getPlaybackStatus: noopAsync,
    getPlaybackPreferences: (opts) => {
      const qs = new URLSearchParams()
      if (opts?.type) qs.set('type', opts.type)
      if (opts?.seriesId) qs.set('series_id', opts.seriesId)
      if (opts?.movieId) qs.set('movie_id', opts.movieId)
      return get(`/api/playback/preferences?${qs}`)
    },
    savePlaybackPreferences: (prefs) => post('/api/playback/preferences', prefs),
    switchAudio: async (audioStreamIndex, currentVideoTime) => {
      if (!activeSessionId) return null
      return post('/api/playback/switch_audio', {
        session: activeSessionId,
        audioStreamIndex,
        currentVideoTime
      })
    },
    switchSubtitle: async (subtitleStreamIndex) => {
      if (!activeSessionId) return null
      return post('/api/playback/switch_subtitle', {
        session: activeSessionId,
        subtitleStreamIndex
      })
    },
    switchBitmapSubtitle: async (subtitleStreamIndex, currentVideoTime) => {
      if (!activeSessionId) return null
      return post('/api/playback/switch_bitmap_subtitle', {
        session: activeSessionId,
        subtitleStreamIndex,
        currentVideoTime
      })
    },

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
  canPlay: true,
  canDownload: false,
  canAdd: false,
  canManage: false,
  canOpenExternal: false,
  hasNowPlaying: false,
  hasSettings: false,
}
