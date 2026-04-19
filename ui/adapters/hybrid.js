/**
 * Hybrid adapter — tries HTTP (Rails API) first, falls back to local (Electron IPC).
 *
 * Design:
 * - Data operations (shows, movies, episodes) prefer HTTP when connected,
 *   fallback to local when not.
 * - Playback: if the media file is accessible locally (e.g. network mount),
 *   use the local transcoder (stream:// protocol). Otherwise use HTTP streaming
 *   from the server (MSE path, same as web app).
 * - File pickers, VLC, downloads, updates, events are ALWAYS local.
 * - Settings are ALWAYS local.
 * - Connection status is tracked and exposed via onConnectionChange callback.
 */
import { createHttpAdapter } from './http.js'
import { createLocalAdapter, localCapabilities } from './local.js'

/**
 * @param {Object} opts
 * @param {string} opts.serverUrl - Rails API base URL
 * @param {boolean} [opts.localPlayback=true] - When true, prefer local transcoder for accessible files. When false, always stream from server.
 * @param {(connected: boolean) => void} [opts.onConnectionChange] - Called when connection status changes
 * @returns {{ adapter: Object, capabilities: Object, destroy: () => void, isConnected: () => boolean }}
 */
export function createHybridAdapter({ serverUrl, localPlayback = true, onConnectionChange }) {
  const http = createHttpAdapter(serverUrl)
  const local = createLocalAdapter()

  let connected = false
  let checking = false
  let pingTimer = null
  let initialCheckDone = false
  let initialCheckPromise = null

  // Track whether current playback session uses local or remote transcoder.
  // 'local' = desktop transcoder + stream:// protocol
  // 'remote' = server transcoder + HTTP streaming (MSE)
  // null = no active playback
  let playbackMode = null

  // --- Connection health ---

  async function checkConnection() {
    if (checking) return connected
    checking = true
    try {
      const res = await fetch(`${serverUrl.replace(/\/+$/, '')}/api/health`, {
        signal: AbortSignal.timeout(5000),
      })
      if (!res.ok) {
        setConnected(false)
      } else {
        const json = await res.json()
        setConnected(json?.status === 'ok')
      }
    } catch {
      setConnected(false)
    } finally {
      checking = false
      initialCheckDone = true
    }
    return connected
  }

  function setConnected(value) {
    if (connected !== value) {
      connected = value
      onConnectionChange?.(value)
    }
  }

  function startPolling() {
    initialCheckPromise = checkConnection()
    pingTimer = setInterval(checkConnection, 30000)
  }

  function stopPolling() {
    if (pingTimer) {
      clearInterval(pingTimer)
      pingTimer = null
    }
  }

  startPolling()

  // --- Helpers ---

  /** Try HTTP, fall back to local on network error */
  function withFallback(httpFn, localFn) {
    return async (...args) => {
      // Wait for initial connection check before deciding
      if (!initialCheckDone && initialCheckPromise) {
        await initialCheckPromise
      }
      if (connected) {
        try {
          return await httpFn(...args)
        } catch (err) {
          if (isNetworkError(err)) {
            setConnected(false)
            console.warn('[hybrid] API unreachable, falling back to local:', err.message)
          } else {
            throw err
          }
        }
      }
      return localFn(...args)
    }
  }

  function isNetworkError(err) {
    if (err.name === 'TypeError' && err.message.includes('fetch')) return true
    if (err.name === 'AbortError') return true
    if (err.message?.includes('NetworkError')) return true
    if (err.message?.includes('Failed to fetch')) return true
    if (err.message?.includes('network')) return true
    if (err.message?.match(/API (502|503|504)/)) return true
    return false
  }

  /** Check if a file path is accessible on the local filesystem.
   *
   * Must use `fs.existsSync` (access(F_OK) syscall), NOT `fs.statSync`.
   * On macOS, TCC treats them differently: access(F_OK) often returns
   * true for files the process can actually read via the binary
   * (ffmpeg/ffprobe launched by Electron.app, which has Files & Folders
   * access granted through the GUI prompt), while stat() fails with
   * EPERM. Using stat() here caused playback to falsely route to the
   * HTTP fallback for perfectly-readable local files. */
  async function fileExistsLocally(filePath) {
    if (!filePath) return false
    try {
      return await window.api.fileExists(filePath)
    } catch {
      return false
    }
  }

  // --- Build adapter ---

  const adapter = {
    // === Data operations: HTTP preferred, local fallback ===

    // Shows
    listShows: withFallback(http.listShows, local.listShows),
    getContinue: withFallback(http.getContinue, local.getContinue),
    // Custom getShow that enriches server data with local download status
    getShow: async (slug) => {
      // Wait for initial connection check before deciding
      if (!initialCheckDone && initialCheckPromise) {
        await initialCheckPromise
      }

      let data = null
      let fromServer = false

      if (connected) {
        try {
          data = await http.getShow(slug)
          fromServer = true
        } catch (err) {
          if (isNetworkError(err)) {
            setConnected(false)
            console.warn('[hybrid] API unreachable, falling back to local:', err.message)
          } else {
            throw err
          }
        }
      }

      if (!data) {
        data = await local.getShow(slug)
        fromServer = false
      }

      // If data came from server, enrich episodes with local download status
      if (data && fromServer && data.episodes && data.episodes.length > 0) {
        const filePaths = data.episodes.map(ep => ep.file_path).filter(Boolean)
        if (filePaths.length > 0) {
          try {
            const downloadStatus = await local.getDownloadStatusByFilePaths(filePaths)
            data.episodes = data.episodes.map(ep => ({
              ...ep,
              download: ep.file_path ? (downloadStatus[ep.file_path] || null) : null,
            }))
          } catch (err) {
            console.warn('[hybrid] Failed to get local download status:', err.message)
          }
        }
      }

      return data
    },
    addShow: local.addShow,
    scanShow: local.scanShow,
    refreshShowMetadata: local.refreshShowMetadata,
    destroyShow: local.destroyShow,
    relocateShow: local.relocateShow,

    // Episodes — playEpisode prefers HTTP (server has authoritative resume state)
    toggleEpisode: withFallback(http.toggleEpisode, local.toggleEpisode),
    getNextEpisode: withFallback(http.getNextEpisode, local.getNextEpisode),
    playEpisode: withFallback(http.playEpisode, local.playEpisode),

    // Movies — playMovie prefers HTTP (server has authoritative resume state)
    listMovies: withFallback(http.listMovies, local.listMovies),
    // Custom getMovie that enriches server data with local download status
    getMovie: async (slug) => {
      if (!initialCheckDone && initialCheckPromise) {
        await initialCheckPromise
      }

      let data = null
      let fromServer = false

      if (connected) {
        try {
          data = await http.getMovie(slug)
          fromServer = true
        } catch (err) {
          if (isNetworkError(err)) {
            setConnected(false)
            console.warn('[hybrid] API unreachable, falling back to local:', err.message)
          } else {
            throw err
          }
        }
      }

      if (!data) {
        data = await local.getMovie(slug)
        fromServer = false
      }

      // If data came from server, enrich with local download status
      if (data && fromServer && data.file_path) {
        try {
          const downloadStatus = await local.getMovieDownloadStatusByFilePath(data.file_path)
          data.download = downloadStatus || null
        } catch (err) {
          console.warn('[hybrid] Failed to get local movie download status:', err.message)
        }
      }

      return data
    },
    addMovies: local.addMovies,
    toggleMovie: withFallback(http.toggleMovie, local.toggleMovie),
    refreshMovieMetadata: local.refreshMovieMetadata,
    destroyMovie: local.destroyMovie,
    relocateMovie: local.relocateMovie,
    playMovie: withFallback(http.playMovie, local.playMovie),

    // === Playback: local if file accessible, else remote (HTTP streaming) ===

    startPlayback: async (filePath, startTime, prefs, options) => {
      // When localPlayback is enabled, check whether the media file is
      // accessible on the local filesystem (e.g. via network mount, NAS
      // share). When disabled, always stream from the server.
      const locallyAccessible = localPlayback && await fileExistsLocally(filePath)

      if (locallyAccessible) {
        playbackMode = 'local'
        return local.startPlayback(filePath, startTime, prefs, options)
      }

      if (connected) {
        try {
          playbackMode = 'remote'
          return await http.startPlayback(filePath, startTime, prefs, options)
        } catch (err) {
          playbackMode = null
          if (isNetworkError(err)) {
            setConnected(false)
          }
          throw err
        }
      }

      playbackMode = null
      return { error: 'File is not accessible locally and the server is unreachable.' }
    },

    stopPlayback: async (finalTime, finalDuration, context) => {
      const mode = playbackMode
      playbackMode = null

      if (mode === 'remote') {
        // Stop the server-side transcoder session
        const result = await http.stopPlayback(finalTime, finalDuration, context).catch(() => null)
        // Also save progress locally so the local DB stays in sync
        local.reportProgress(finalTime, finalDuration)
        return result
      }

      // Local mode: stop local transcoder
      const result = await local.stopPlayback(finalTime, finalDuration, context)
      // Also report final position to server so other devices see it
      if (connected && context && finalTime != null) {
        http.reportProgress(finalTime, finalDuration, context).catch(() => {})
      }
      return result
    },

    setPlaybackEpisode: local.setPlaybackEpisode,
    setPlaybackMovie: local.setPlaybackMovie,

    seekPlayback: async (seekTime) => {
      if (playbackMode === 'remote') {
        return http.seekPlayback(seekTime)
      }
      return local.seekPlayback(seekTime)
    },

    reportProgress: (time, duration, context) => {
      // Always save locally
      local.reportProgress(time, duration)
      // Fire-and-forget to server
      if (connected && context) {
        http.reportProgress(time, duration, context).catch(err => {
          if (isNetworkError(err)) setConnected(false)
        })
      }
    },

    getPlaybackStatus: local.getPlaybackStatus,
    getPlaybackPreferences: withFallback(http.getPlaybackPreferences, local.getPlaybackPreferences),
    savePlaybackPreferences: withFallback(http.savePlaybackPreferences, local.savePlaybackPreferences),

    switchAudio: async (index, time) => {
      if (playbackMode === 'remote') {
        return http.switchAudio(index, time)
      }
      return local.switchAudio(index, time)
    },

    switchSubtitle: async (index) => {
      if (playbackMode === 'remote') {
        return http.switchSubtitle(index)
      }
      return local.switchSubtitle(index)
    },

    switchBitmapSubtitle: async (index, time) => {
      if (playbackMode === 'remote') {
        return http.switchBitmapSubtitle(index, time)
      }
      return local.switchBitmapSubtitle(index, time)
    },

    // === VLC: ALWAYS local ===
    checkVlc: local.checkVlc,
    openInVlc: local.openInVlc,
    openInDefault: local.openInDefault,

    // === Downloads: ALWAYS local ===
    downloadEpisode: local.downloadEpisode,
    deleteDownloadEpisode: local.deleteDownloadEpisode,
    downloadSeason: local.downloadSeason,
    deleteDownloadSeason: local.deleteDownloadSeason,
    downloadMovie: local.downloadMovie,
    deleteDownloadMovie: local.deleteDownloadMovie,
    getDownloadStatusByFilePaths: local.getDownloadStatusByFilePaths,
    getMovieDownloadStatusByFilePath: local.getMovieDownloadStatusByFilePath,

    // === Settings: ALWAYS local ===
    getSettings: local.getSettings,
    setSyncFolder: local.setSyncFolder,
    syncNow: local.syncNow,
    loadFromSync: local.loadFromSync,

    // === File pickers: ALWAYS local ===
    selectFolder: local.selectFolder,
    selectFiles: local.selectFiles,

    // === Events: ALWAYS local ===
    onVlcPlaybackEnded: local.onVlcPlaybackEnded,
    onMediaDownloadProgress: local.onMediaDownloadProgress,
    onSubtitlesReady: local.onSubtitlesReady,

    // === Updates: ALWAYS local ===
    checkForUpdate: local.checkForUpdate,
    onUpdateAvailable: local.onUpdateAvailable,
    onDownloadProgress: local.onDownloadProgress,
    downloadUpdate: local.downloadUpdate,
    installUpdate: local.installUpdate,

    // === Admin: ALWAYS http (server-only). No fallback — if the server is
    // unreachable the admin call should error rather than silently no-op
    // against local state, which doesn't have the concept of media folders.
    listMediaFolders: http.listMediaFolders,
    addMediaFolder: http.addMediaFolder,
    updateMediaFolder: http.updateMediaFolder,
    removeMediaFolder: http.removeMediaFolder,
    browseServerPath: http.browseServerPath,
    listPendingImports: http.listPendingImports,
    confirmPendingImport: http.confirmPendingImport,
    ignorePendingImport: http.ignorePendingImport,
    researchPendingImport: http.researchPendingImport,
    triggerAdminScan: http.triggerAdminScan,
  }

  // --- Hybrid capabilities ---
  // API mode means the server manages the library, so disable file-system
  // operations (add, rescan, refresh, relocate, remove). Downloads and VLC
  // remain available since they're inherently local. Admin is enabled
  // because hybrid mode is connected to a server.
  const capabilities = {
    ...localCapabilities,
    canAdd: false,
    canManage: false,
    canAdmin: true,
  }

  return {
    adapter,
    capabilities,
    destroy: stopPolling,
    isConnected: () => connected,
    checkConnection,
  }
}
