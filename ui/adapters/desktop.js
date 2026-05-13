/**
 * Desktop adapter — HTTP to the Rails server, plus electron-only extras.
 *
 * Used by the desktop Electron app. The server owns all data, scanning,
 * metadata, transcoding, and watch state. The adapter layers on top:
 *   - native dialogs (download destination)
 *   - downloads (streams server raw files to disk)
 *   - external VLC launcher + library control (open-in-vlc)
 *   - mDNS server discovery
 *   - electron-updater
 *
 * Playback itself flows through the same Jellyfin Player JS runtime as the
 * browser: the desktop adapter does not own an alternate player engine.
 */
import { createHttpAdapter, httpCapabilities } from './http.js'
import { buildDesktopProfile } from './device-profile.js'

export function createDesktopAdapter(serverUrl) {
  const buildProfile = () => buildDesktopProfile()
  const http = createHttpAdapter(serverUrl, { buildProfile })
  const base = serverUrl.replace(/\/+$/, '')

  // Resolve a server-relative URL into an absolute URL for downstream tools
  // (VLC, default-app handlers) that need the full host.
  const absoluteUrl = (url) => {
    if (!url) return url
    if (/^https?:\/\//i.test(url)) return url
    if (url.startsWith('/')) return `${base}${url}`
    return url
  }

  return {
    ...http,

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

    // === Desktop preferences (server URL, downloads folder) ===
    getDesktopPreferences: () => window.api.getPreferences(),
    setDesktopPreferences: (prefs) => window.api.setPreferences(prefs),
  }
}

export function getDesktopCapabilities() {
  return {
    ...httpCapabilities,
    canPlay: true,
    canDownload: true,
    canOpenExternal: true,
    hasNowPlaying: true,
    hasSettings: true,
    hasUpdater: true,
    hasServerDiscovery: true,
    hasVlcLibrary: true,
    canAdmin: true,
    canAdd: false,
    canManage: false,
  }
}

export const desktopCapabilities = getDesktopCapabilities()
