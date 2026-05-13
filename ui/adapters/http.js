/**
 * HTTP adapter — calls Rails API via fetch.
 * Used by web app and desktop in server mode.
 *
 * Codec/format capabilities are advertised via a DeviceProfile sent on
 * every POST /api/playback/start. Each client supplies its own profile
 * builder via the `buildProfile` constructor option. See
 * ./device-profile.js for the canonical builders.
 */

import { buildBrowserProfile } from './device-profile.js'

export function createHttpAdapter(baseUrl = 'http://localhost:3000', { buildProfile } = {}) {
  const base = baseUrl.replace(/\/+$/, '')
  // Profile is built once and reused. Browsers only — desktop/android
  // pass their own builder. Cached at adapter construction so MSE probes
  // run a single time per session.
  const profile = (buildProfile || buildBrowserProfile)()

  // Active playback session ID (set by startPlayback, cleared by stopPlayback)
  let activeSessionId = null

  function buildHeaders(extra = {}) {
    const headers = { ...extra }
    try {
      if (typeof localStorage !== 'undefined' && localStorage.getItem('__caramba_test_run__') === '1') {
        headers['X-Test-Run'] = '1'
      }
    } catch {}
    return headers
  }

  async function request(path, opts = {}) {
    const url = `${base}${path}`
    const config = { ...opts }
    if (config.body && typeof config.body === 'object') {
      config.headers = buildHeaders({ 'Content-Type': 'application/json', ...config.headers })
      config.body = JSON.stringify(config.body)
    } else {
      config.headers = buildHeaders(config.headers)
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

  const noop = () => {}
  const noopAsync = async () => null
  const noopUnsub = () => noop

  return {
    // Server base URL — read by the Android native player so its Activity
    // can POST progress directly to Rails (the JS bridge is unreliable while
    // the player Activity is on top of the WebView).
    apiBase: base,

    // Shows
    listShows: () => get('/api/shows'),
    getContinue: (slug) => get(`/api/shows/${slug}/continue`),
    getShow: (slug) => get(`/api/shows/${slug}/full`),
    addShow: noopAsync,
    scanShow: noopAsync,
    refreshShowMetadata: noopAsync,
    destroyShow: noopAsync,
    relocateShow: noopAsync,

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
    startPlayback: async (filePath, startTime, prefs, _options) => {
      const result = await post('/api/playback/start', {
        filePath,
        startTime,
        prefs,
        deviceProfile: profile,
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
    pausePlayback: noopAsync,
    resumePlayback: noopAsync,
    addExternalSubtitle: noopAsync,
    setSubtitleAppearance: noopAsync,
    reportProgress: async (videoTime, videoDuration, context) => {
      return post('/api/playback/report_progress', {
        time: videoTime,
        duration: videoDuration,
        episode_id: context?.episodeId,
        movie_id: context?.movieId,
        watch_history_id: context?.watchHistoryId,
      })
    },
    getPlaybackStatus: noopAsync,
    getPlaybackPreferences: (opts) => {
      const qs = new URLSearchParams()
      if (opts?.type) qs.set('type', opts.type)
      if (opts?.showId) qs.set('show_id', opts.showId)
      if (opts?.movieId) qs.set('movie_id', opts.movieId)
      return get(`/api/playback/preferences?${qs}`)
    },
    savePlaybackPreferences: (prefs) => post('/api/playback/preferences', prefs),

    // VLC — no-ops
    checkVlc: async () => false,
    openInVlc: noopAsync,
    openInDefault: noopAsync,

    // external VLC library control — no-ops in pure HTTP mode
    vlcStatus: noopAsync,
    vlcPause: noopAsync,
    vlcResume: noopAsync,
    vlcStop: noopAsync,
    vlcSeek: noopAsync,
    vlcSetVolume: noopAsync,

    // Downloads — no-ops
    downloadEpisode: noopAsync,
    deleteDownloadEpisode: noopAsync,
    downloadSeason: noopAsync,
    deleteDownloadSeason: noopAsync,
    downloadMovie: noopAsync,
    deleteDownloadMovie: noopAsync,

    // Settings — no-ops
    getSettings: noopAsync,
    setSyncFolder: noopAsync,
    syncNow: noopAsync,
    loadFromSync: noopAsync,

    // File pickers — no-ops
    selectFolder: noopAsync,
    selectFiles: noopAsync,

    // Events — no-op subscribers (embed engine events only fire in local mode).
    onVlcPlaybackEnded: noopUnsub,
    onMediaDownloadProgress: noopUnsub,
    onPlaybackState: noopUnsub,
    onPlaybackTracks: noopUnsub,
    onPlaybackEnded: noopUnsub,

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

    // Admin
    listMediaFolders: () => get('/api/admin/folders'),
    addMediaFolder: ({ path, kind }) => post('/api/admin/folders', { path, kind }),
    updateMediaFolder: (id, attrs) => request(`/api/admin/folders/${id}`, { method: 'PATCH', body: attrs }),
    removeMediaFolder: (id) => request(`/api/admin/folders/${id}`, { method: 'DELETE' }),
    browseServerPath: (path) => {
      const qs = new URLSearchParams()
      if (path) qs.set('path', path)
      return get(`/api/admin/browse${qs.toString() ? `?${qs}` : ''}`)
    },
    listPendingImports: (status) => {
      const qs = new URLSearchParams()
      if (status) qs.set('status', status)
      return get(`/api/admin/pending_imports${qs.toString() ? `?${qs}` : ''}`)
    },
    confirmPendingImport: (id, externalId) => post(`/api/admin/pending_imports/${id}/confirm`, { externalId }),
    ignorePendingImport: (id) => post(`/api/admin/pending_imports/${id}/ignore`),
    researchPendingImport: (id) => post(`/api/admin/pending_imports/${id}/research`),
    switchPendingImportKind: (id, kind) => post(`/api/admin/pending_imports/${id}/switch_kind`, { kind }),
    triggerAdminScan: () => post('/api/admin/scan'),
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
  canAdmin: true,
  hasNativePlayer: false, // overridden true on Android TV when CarambaPlayer Capacitor plugin is registered
  hasVlcLibrary: false,
  hasMpvEmbedPlayer: false,
  // Desktop-only flags — declared here as `false` so every consumer can read
  // `capabilities.hasUpdater` etc without an undefined check.
  hasUpdater: false,
  hasServerDiscovery: false,
}
