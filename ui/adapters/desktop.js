/**
 * Desktop adapter — HTTP to the Rails server, plus electron-only extras.
 *
 * Used by the desktop Electron app. The server owns all data, scanning,
 * metadata, transcoding, and watch state. The adapter layers on top:
 *   - native dialogs (download destination)
 *   - downloads (streams server raw files to disk)
 *   - external VLC launcher + library control (open-in-vlc)
 *   - embedded libmpv pointed at the server's URL (default engine)
 *   - mDNS server discovery
 *   - electron-updater
 */
import { createHttpAdapter, httpCapabilities } from './http.js'
import { buildDesktopProfile } from './device-profile.js'

/**
 * @param {string} serverUrl - Rails API base URL (e.g. "http://192.168.1.10:3001")
 * @param {Object} [opts]
 * @param {boolean} [opts.useEmbedMpv=true] - When true, route playback through the
 *   embedded libmpv engine (renders into the BrowserWindow's NSView). When false,
 *   the renderer plays the server's HLS URL directly via hls.js — narrower codec
 *   coverage but no native module dependency.
 * @param {Object} [opts.mpvCapabilities] - Decoders/demuxers reported by libmpv
 *   (window.api.getMpvCapabilities()). When provided, the device profile is
 *   built dynamically from the engine's actual codec list. When omitted, a
 *   conservative hardcoded fallback profile is used.
 */
export function createDesktopAdapter(serverUrl, { useEmbedMpv = true, mpvCapabilities } = {}) {
  // Build a profile matching the active engine. libmpv has broad codec
  // coverage (HEVC HDR, lossless audio, PGS subs, etc.), so the server
  // can skip transcode for far more files when the embed engine is on.
  const buildProfile = () => buildDesktopProfile({
    engine: useEmbedMpv ? 'libmpv' : 'browser',
    capabilities: useEmbedMpv ? mpvCapabilities : undefined,
  })
  const http = createHttpAdapter(serverUrl, { buildProfile })
  const base = serverUrl.replace(/\/+$/, '')

  // Resolve a server-relative URL (e.g. "/api/playback/hls/abc.m3u8") into an
  // absolute URL libmpv can consume.
  const absoluteUrl = (url) => {
    if (!url) return url
    if (/^https?:\/\//i.test(url)) return url
    if (url.startsWith('/')) return `${base}${url}`
    return url
  }

  return {
    ...http,

    // === Playback ===
    // Server always starts the session; if the mpv engine is selected,
    // hand the returned URL to the in-process libmpv and suppress the
    // renderer-side URL so VideoPlayer mounts the embed overlay instead
    // of WebVideoPlayer.
    startPlayback: async (filePath, startTime, prefs, options) => {
      const result = await http.startPlayback(filePath, startTime, prefs, options)
      if (!result || result.error) return result

      if (useEmbedMpv && (result.hlsUrl || result.streamUrl)) {
        const url = absoluteUrl(result.hlsUrl || result.streamUrl)
        let mpvOk = false
        let mpvError = null
        let mpvResult = null
        try {
          mpvResult = await window.api.startEmbedMpv(url, { startTime, prefs })
          // libmpv's start IPC currently returns { ok: true, duration, tracks }
          // even when it silently fails to load the file (the binding
          // queues `loadfile` and returns synchronously without waiting
          // for MPV_EVENT_FILE_LOADED). Detect silent failure by
          // checking whether mpv produced track or duration info — a
          // successful load always populates both.
          const reportsLoad = mpvResult && mpvResult.ok &&
                              (mpvResult.duration > 0 ||
                               (Array.isArray(mpvResult.audioStreams) && mpvResult.audioStreams.length > 0))
          if (reportsLoad) {
            mpvOk = true
          } else {
            mpvError = new Error('libmpv start returned without loading the file (duration=0, tracks=0) — engine stalled silently')
          }
        } catch (err) {
          mpvError = err
        }

        if (mpvOk) {
          return { ...result, hlsUrl: null, streamUrl: null }
        }

        // Fallback to hls.js. Surface loudly — silent degradation hides
        // libmpv regressions, and we still want a working renderer.
        console.warn('[desktop] libmpv start failed, falling back to hls.js:', mpvError?.message || mpvError)
        try {
          const Sentry = (typeof window !== 'undefined' && window.Sentry) || null
          Sentry?.addBreadcrumb?.({
            category: 'desktop-player',
            level: 'warning',
            message: 'libmpv_start_failed_fallback_to_hlsjs',
            data: { error: mpvError?.message, filePath, strategy: result.strategy },
          })
        } catch {}
        try { window.__caramba_engine_fallback__ = true } catch {}
        // Also stop the mpv handle so it doesn't compete for the
        // BrowserWindow's NSView while hls.js renders <video>.
        try { await window.api.stopEmbedMpv() } catch {}
      }
      return result
    },

    stopPlayback: async (finalTime, finalDuration, context) => {
      if (useEmbedMpv) {
        try { await window.api.stopEmbedMpv() } catch {}
      }
      return http.stopPlayback(finalTime, finalDuration, context)
    },

    seekPlayback: async (seekTime) => {
      if (useEmbedMpv) {
        try { await window.api.embedSeek(seekTime); return { ok: true } } catch {}
      }
      return http.seekPlayback(seekTime)
    },

    pausePlayback: async () => {
      if (useEmbedMpv) {
        try { await window.api.embedPause(); return { ok: true } } catch {}
      }
      return http.pausePlayback()
    },

    resumePlayback: async () => {
      if (useEmbedMpv) {
        try { await window.api.embedResume(); return { ok: true } } catch {}
      }
      return http.resumePlayback()
    },

    switchAudio: useEmbedMpv
      ? async (id) => { try { return await window.api.embedSwitchAudio(id) } catch { return null } }
      : http.switchAudio,

    switchSubtitle: useEmbedMpv
      ? async (id) => { try { return await window.api.embedSwitchSubtitle(id) } catch { return null } }
      : http.switchSubtitle,

    // libmpv live-state events. In hls.js mode these never fire;
    // PlayerContext only subscribes when capabilities.hasMpvEmbedPlayer is true.
    onPlaybackState: (cb) => window.api.onPlaybackState(cb),
    onPlaybackTracks: (cb) => window.api.onPlaybackTracks(cb),
    onPlaybackEnded: (cb) => window.api.onPlaybackEnded(cb),

    // === External VLC / Open in default app ===
    // The renderer passes { filePath, episodeId, movieId, title }. We start a
    // server playback session to get a stable HLS URL, then hand that URL to
    // the local VLC subprocess (or the OS default handler).
    checkVlc: () => window.api.checkVlc(),
    openInVlc: async ({ filePath, episodeId, movieId, title } = {}) => {
      if (!filePath) return { error: 'No file path' }
      const session = await http.startPlayback(filePath, 0, null, {})
      if (!session || session.error) return session || { error: 'Failed to start session' }
      const url = absoluteUrl(session.hlsUrl || session.streamUrl)
      if (!url) return { error: 'Server did not return a playback URL.' }
      return window.api.openInVlc({ url, episodeId, movieId, title })
    },
    openInDefault: async (filePath, episodeId, movieId) => {
      if (!filePath) return { error: 'No file path' }
      const session = await http.startPlayback(filePath, 0, null, {})
      if (!session || session.error) return session || { error: 'Failed to start session' }
      const url = absoluteUrl(session.hlsUrl || session.streamUrl)
      if (!url) return { error: 'Server did not return a playback URL.' }
      return window.api.openInDefault({ url, episodeId, movieId })
    },

    // External VLC library polling — drives the NowPlaying VLC bar.
    getPlaybackStatus: () => window.api.getPlaybackStatus(),
    onVlcPlaybackEnded: (cb) => window.api.onVlcPlaybackEnded(cb),

    // External VLC library control surface (pause/seek the external VLC).
    vlcStatus: () => window.api.vlcStatus(),
    vlcPause: () => window.api.vlcPause(),
    vlcResume: () => window.api.vlcResume(),
    vlcStop: () => window.api.vlcStop(),
    vlcSeek: (seconds) => window.api.vlcSeek(seconds),
    vlcSetVolume: (level) => window.api.vlcSetVolume(level),

    // === Downloads (electron-only) ===
    // Server exposes raw file streams at /api/media/{episodes,movies}/:id
    // — the desktop just streams them to disk and tracks progress in memory.
    downloadEpisode: ({ episodeId, label, originalName, filePath } = {}) => {
      if (!episodeId) return Promise.resolve({ error: 'No episodeId' })
      const url = `${base}/api/media/episodes/${episodeId}`
      return window.api.downloadEpisode({
        episodeId,
        url,
        label: label || `ep${episodeId}`,
        originalName: originalName || filePath || `episode_${episodeId}.mkv`,
      })
    },
    deleteDownloadEpisode: ({ episodeId } = {}) => {
      return window.api.deleteDownloadEpisode({ episodeId })
    },
    downloadMovie: ({ movieSlug, movieId, label, originalName, filePath } = {}) => {
      if (!movieId && !movieSlug) return Promise.resolve({ error: 'No movie identifier' })
      const url = movieId ? `${base}/api/media/movies/${movieId}` : null
      if (!url) return Promise.resolve({ error: 'movieId is required for downloads (used to resolve server file URL).' })
      return window.api.downloadMovie({
        movieSlug: movieSlug || String(movieId),
        url,
        label: label || movieSlug || String(movieId),
        originalName: originalName || filePath || `movie_${movieId}.mkv`,
      })
    },
    deleteDownloadMovie: ({ movieSlug, movieId } = {}) => {
      return window.api.deleteDownloadMovie({ movieSlug: movieSlug || String(movieId || '') })
    },
    getDownloadStatus: (payload) => window.api.getDownloadStatus(payload),
    listDownloads: () => window.api.listDownloads(),
    onMediaDownloadProgress: (cb) => window.api.onMediaDownloadProgress(cb),

    // === File pickers (downloads destination) ===
    selectFolder: () => window.api.selectFolder(),

    // === Server discovery (mDNS) ===
    discoverServers: () => window.api.discoverServers(),

    // === Auto-updater ===
    checkForUpdate: () => window.api.checkForUpdate(),
    onUpdateAvailable: (cb) => window.api.onUpdateAvailable(cb),
    onDownloadProgress: (cb) => window.api.onDownloadProgress(cb),
    downloadUpdate: () => window.api.downloadUpdate(),
    installUpdate: () => window.api.installUpdate(),

    // === Desktop preferences (server URL, player engine, downloads folder) ===
    getDesktopPreferences: () => window.api.getPreferences(),
    setDesktopPreferences: (prefs) => window.api.setPreferences(prefs),
  }
}

/**
 * Default capabilities for the desktop client. `hasMpvEmbedPlayer` mirrors
 * the `useEmbedMpv` option passed into createDesktopAdapter — toggle the
 * two together when the user changes the player engine in Settings.
 */
export function getDesktopCapabilities({ useEmbedMpv = true } = {}) {
  return {
    ...httpCapabilities,
    canPlay: true,
    canDownload: true,
    canOpenExternal: true,
    hasNowPlaying: true,
    hasSettings: true,
    hasMpvEmbedPlayer: useEmbedMpv,
    hasUpdater: true,
    hasServerDiscovery: true,
    hasVlcLibrary: true,
    canAdmin: true,
    canAdd: false,
    canManage: false,
  }
}

export const desktopCapabilities = getDesktopCapabilities()
