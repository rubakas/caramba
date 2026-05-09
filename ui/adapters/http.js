/**
 * HTTP adapter — calls Rails API via fetch.
 * Used by web app and desktop in server mode.
 */

// Probe the browser's MSE decoder support once. The server uses this to
// decide whether to direct-play HEVC (fast, high-quality) or force a
// transcode to H.264 (slower but universally supported). Android WebView
// in particular often lacks MSE HEVC support even when the device itself
// can hardware-decode HEVC in other contexts.
//
// hevc10 (HEVC Main 10 / 4K HDR) drives the HDR direct-stream path on the
// server. When true the server skips the 10-bit guard and remuxes the
// source as-is — keeps true HDR, zero re-encode. We force it to false in
// Electron because Chromium 130 / Electron 33 MSE accepts the codec string
// but the decoder stalls on actual 10-bit playback (no frames produced).
// Real browsers (Safari, Chrome 107+) decode 10-bit HEVC reliably.
function isElectronRuntime() {
  if (typeof navigator === 'undefined') return false
  return /\bElectron\b/.test(navigator.userAgent || '')
}

function detectCodecSupport() {
  if (typeof MediaSource === 'undefined' || typeof MediaSource.isTypeSupported !== 'function') {
    return { h264: true, hevc: false, hevc10: false, audio: { aac: true } }
  }
  const test = (type) => { try { return MediaSource.isTypeSupported(type) } catch { return false } }
  const hevc = test('video/mp4; codecs="hvc1.1.6.L120.B0"') || test('video/mp4; codecs="hev1.1.6.L120.B0"')
  // Main 10 profile (`.2.4.`) at level 5.0 — the smallest level that covers
  // 4K HDR sources. Suppressed on Electron until the upstream MSE bug is
  // resolved.
  const hevc10 = !isElectronRuntime() && (
    test('video/mp4; codecs="hvc1.2.4.L150.B0"') ||
    test('video/mp4; codecs="hev1.2.4.L150.B0"')
  )
  // Audio codecs the browser MSE can decode in fMP4 segments. Lets the
  // server skip audio_transcode when the source already matches. AAC is
  // assumed everywhere; the others vary (Firefox lacks AC3/EAC3, Safari
  // lacks Opus, etc.). TrueHD/DTS-HD are never in MSE — those always
  // transcode.
  const audio = {
    // AAC is unconditionally true: every MSE-capable browser supports it,
    // and some return false for the exact `mp4a.40.2` string while playing
    // it in practice.
    aac:  true,
    ac3:  test('audio/mp4; codecs="ac-3"'),
    eac3: test('audio/mp4; codecs="ec-3"'),
    flac: test('audio/mp4; codecs="flac"'),
    mp3:  test('audio/mp4; codecs="mp4a.40.34"') || test('audio/mp4; codecs="mp3"'),
    opus: test('audio/mp4; codecs="opus"'),
  }
  return {
    h264: test('video/mp4; codecs="avc1.640028"'),
    hevc,
    hevc10,
    audio,
  }
}

let _codecSupport = null
function codecSupport() {
  if (_codecSupport === null) _codecSupport = detectCodecSupport()
  return _codecSupport
}

// What ExoPlayer (Media3) can decode natively. Wider than MSE — when
// `nativePlayer:true` is set the server skips ffmpeg entirely and just
// serves the source file via /api/playback/file. ExoPlayer's
// MatroskaExtractor reads MKV directly, decoding HEVC HDR + AC-3 /
// E-AC-3 / TrueHD / DTS audio + PGS bitmap / SubRip / ASS subtitles —
// all the codecs that would otherwise force audio_transcode or full_transcode.
const NATIVE_PLAYER_CODEC_SUPPORT = Object.freeze({
  h264: true,
  hevc: true,
  hevc10: true,
  nativePlayer: true,
  audio: Object.freeze({
    aac: true, ac3: true, eac3: true, flac: true, mp3: true, opus: true,
    // ExoPlayer's hardware decoders can usually handle these too;
    // signaling them lets the server skip audio_transcode for
    // multi-channel lossless streams.
    truehd: true, dts: true, dtshd: true,
  }),
})

export function createHttpAdapter(baseUrl = 'http://localhost:3000', { useNativePlayerCodecs = false } = {}) {
  const base = baseUrl.replace(/\/+$/, '')
  const codecSupportForRequests = () => useNativePlayerCodecs ? NATIVE_PLAYER_CODEC_SUPPORT : codecSupport()

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
    startPlayback: async (filePath, startTime, prefs, options) => {
      const result = await post('/api/playback/start', {
        filePath,
        startTime,
        prefs,
        codecSupport: codecSupportForRequests(),
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

    // libVLC library control (card #60) — no-ops in pure HTTP mode
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

    // Events — no-op subscribers (libVLC events only fire in local mode).
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
  hasVlcEmbedPlayer: false,
}
