/**
 * HTTP adapter — calls Rails API via fetch.
 * Used by web app and desktop in server mode.
 */

// Probe the browser's MSE decoder support once. The server uses this to
// decide whether to direct-play HEVC (fast, high-quality) or force a
// transcode to H.264 (slower but universally supported). Android WebView
// in particular often lacks MSE HEVC support even when the device itself
// can hardware-decode HEVC in other contexts.
function detectCodecSupport() {
  if (typeof MediaSource === 'undefined' || typeof MediaSource.isTypeSupported !== 'function') {
    return { h264: true, hevc: false }
  }
  const test = (type) => { try { return MediaSource.isTypeSupported(type) } catch { return false } }
  return {
    h264: test('video/mp4; codecs="avc1.640028"'),
    hevc: test('video/mp4; codecs="hvc1.1.6.L120.B0"') || test('video/mp4; codecs="hev1.1.6.L120.B0"'),
  }
}

let _codecSupport = null
function codecSupport() {
  if (_codecSupport === null) _codecSupport = detectCodecSupport()
  return _codecSupport
}

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
    getContinue: (slug) => get(`/api/series/${slug}/continue`),
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
    startPlayback: async (filePath, startTime, prefs, options) => {
      const result = await post('/api/playback/start', {
        filePath,
        startTime,
        prefs,
        codecSupport: codecSupport(),
        forceTranscode: !!options?.forceTranscode,
      })
      if (result && result.sessionId) {
        activeSessionId = result.sessionId
      }
      return result
    },
    stopPlayback: async (finalTime, finalDuration, context) => {
      const sid = activeSessionId
      activeSessionId = null
      if (!sid) return null
      return post('/api/playback/stop', {
        session: sid,
        time: finalTime,
        duration: finalDuration,
        episode_id: context?.episodeId,
        movie_id: context?.movieId,
      })
    },
    setPlaybackEpisode: noopAsync, // folded into server-side session state
    setPlaybackMovie: noopAsync,   // folded into server-side session state
    seekPlayback: async (seekTime) => {
      if (!activeSessionId) return null
      return post('/api/playback/seek', { session: activeSessionId, seekTime })
    },
    reportProgress: async (videoTime, videoDuration, context) => {
      return post('/api/playback/report_progress', {
        time: videoTime,
        duration: videoDuration,
        episode_id: context?.episodeId,
        movie_id: context?.movieId,
      })
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
    addToWatchlist: (item) => post('/api/watchlist', item),
    removeFromWatchlist: (identifier) => {
      // identifier can be a tvmaze_id (number) or { _type: 'movie', imdb_id }
      if (typeof identifier === 'object' && identifier._type === 'movie') {
        return del(`/api/watchlist/0?imdb_id=${encodeURIComponent(identifier.imdb_id)}`)
      }
      return del(`/api/watchlist/0?tvmaze_id=${encodeURIComponent(identifier)}`)
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

    // Updates — use Capacitor CarambaUpdater plugin if available, otherwise no-ops
    checkForUpdate: async () => {
      if (typeof window !== 'undefined' && window.Capacitor?.Plugins?.CarambaUpdater) {
        return window.Capacitor.Plugins.CarambaUpdater.checkForUpdate()
      }
      return null
    },
    onUpdateAvailable: noopUnsub, // Not needed — we check manually on load
    onDownloadProgress: (cb) => {
      if (typeof window !== 'undefined' && window.Capacitor?.Plugins?.CarambaUpdater) {
        let handle = null
        const result = window.Capacitor.Plugins.CarambaUpdater.addListener('downloadProgress', cb)
        // Handle both Promise (Capacitor 6+) and sync (older) returns
        if (result && typeof result.then === 'function') {
          result.then(h => { handle = h }).catch(() => {})
        } else if (result) {
          handle = result
        }
        return () => {
          if (handle && handle.remove) handle.remove()
        }
      }
      return noop
    },
    downloadUpdate: async () => {
      if (typeof window !== 'undefined' && window.Capacitor?.Plugins?.CarambaUpdater) {
        return window.Capacitor.Plugins.CarambaUpdater.downloadUpdate()
      }
      return { ok: false, error: 'Updates not available' }
    },
    installUpdate: async () => {
      if (typeof window !== 'undefined' && window.Capacitor?.Plugins?.CarambaUpdater) {
        return window.Capacitor.Plugins.CarambaUpdater.installUpdate()
      }
      return { ok: false, error: 'Updates not available' }
    },
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
