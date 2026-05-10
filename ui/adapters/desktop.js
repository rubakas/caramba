/**
 * Desktop adapter — HTTP to the Rails server, plus electron-only extras.
 *
 * Used by the desktop Electron app. The server owns all data, scanning,
 * metadata, transcoding, and watch state. The adapter layers on top:
 *   - native dialogs (download destination)
 *   - downloads (streams server raw files to disk)
 *   - external VLC launcher + libVLC library (open-in-vlc)
 *   - embedded libVLC pointed at the server's HLS URL (optional engine)
 *   - mDNS server discovery
 *   - electron-updater
 */
import { createHttpAdapter, httpCapabilities } from './http.js'

/**
 * @param {string} serverUrl - Rails API base URL (e.g. "http://192.168.1.10:3001")
 * @param {Object} [opts]
 * @param {boolean} [opts.useEmbedVlc=false] - When true, route playback through the
 *   embedded libVLC engine (renders into the BrowserWindow's NSView). Otherwise
 *   the renderer plays the server's HLS URL directly via hls.js.
 */
export function createDesktopAdapter(serverUrl, { useEmbedVlc = false } = {}) {
  const http = createHttpAdapter(serverUrl)
  const base = serverUrl.replace(/\/+$/, '')

  // Resolve a server-relative URL (e.g. "/api/playback/hls/abc.m3u8") into an
  // absolute URL libVLC can consume.
  const absoluteUrl = (url) => {
    if (!url) return url
    if (/^https?:\/\//i.test(url)) return url
    if (url.startsWith('/')) return `${base}${url}`
    return url
  }

  return {
    ...http,

    // === Playback ===
    // Server always starts the session; if libVLC engine is selected, point
    // it at the server's HLS URL and suppress the renderer-side URL so
    // VideoPlayer mounts VlcOverlay instead of WebVideoPlayer.
    startPlayback: async (filePath, startTime, prefs, options) => {
      const result = await http.startPlayback(filePath, startTime, prefs, options)
      if (!result || result.error) return result

      if (useEmbedVlc && (result.hlsUrl || result.streamUrl)) {
        const url = absoluteUrl(result.hlsUrl || result.streamUrl)
        try {
          await window.api.startEmbedVlc(url, { startTime, prefs })
          return { ...result, hlsUrl: null, streamUrl: null }
        } catch (err) {
          console.warn('[desktop] libVLC start failed, falling back to hls.js:', err)
        }
      }
      return result
    },

    stopPlayback: async (finalTime, finalDuration, context) => {
      if (useEmbedVlc) {
        try { await window.api.stopEmbedVlc() } catch {}
      }
      return http.stopPlayback(finalTime, finalDuration, context)
    },

    seekPlayback: async (seekTime) => {
      if (useEmbedVlc) {
        try { await window.api.embedSeek(seekTime); return { ok: true } } catch {}
      }
      return http.seekPlayback(seekTime)
    },

    pausePlayback: async () => {
      if (useEmbedVlc) {
        try { await window.api.embedPause(); return { ok: true } } catch {}
      }
      return http.pausePlayback()
    },

    resumePlayback: async () => {
      if (useEmbedVlc) {
        try { await window.api.embedResume(); return { ok: true } } catch {}
      }
      return http.resumePlayback()
    },

    switchAudio: useEmbedVlc
      ? async (id) => { try { return await window.api.embedSwitchAudio(id) } catch { return null } }
      : http.switchAudio,

    switchSubtitle: useEmbedVlc
      ? async (id) => { try { return await window.api.embedSwitchSubtitle(id) } catch { return null } }
      : http.switchSubtitle,

    // libVLC live-state events. In hls.js mode these never fire; PlayerContext
    // only subscribes when capabilities.hasVlcEmbedPlayer is true.
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

    // libVLC library polling — drives the NowPlaying VLC bar.
    getPlaybackStatus: () => window.api.getPlaybackStatus(),
    onVlcPlaybackEnded: (cb) => window.api.onVlcPlaybackEnded(cb),

    // libVLC library control surface (pause/seek the external VLC).
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
 * Default capabilities for the desktop client. `hasVlcEmbedPlayer` mirrors
 * the same-named option passed into createDesktopAdapter — toggle the two
 * together when the user changes the player engine in Settings.
 */
export function getDesktopCapabilities({ useEmbedVlc = false } = {}) {
  return {
    ...httpCapabilities,
    canPlay: true,
    canDownload: true,
    canOpenExternal: true,
    hasNowPlaying: true,
    hasSettings: true,
    hasVlcEmbedPlayer: useEmbedVlc,
    hasUpdater: true,
    hasServerDiscovery: true,
    hasVlcLibrary: true,
    canAdmin: true,
    canAdd: false,
    canManage: false,
  }
}

export const desktopCapabilities = getDesktopCapabilities()
