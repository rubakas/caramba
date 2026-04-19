/**
 * Local adapter — delegates to window.api (Electron IPC).
 * Used by desktop app in local mode.
 */
export function createLocalAdapter() {
  const api = window.api

  return {
    // Series
    listSeries: () => api.listSeries(),
    getContinue: (slug) => api.getContinue(slug),
    getSeriesShow: (slug) => api.getSeriesShow(slug),
    addSeries: (path) => api.addSeries(path),
    scanSeries: (slug) => api.scanSeries(slug),
    refreshSeriesMetadata: (slug) => api.refreshSeriesMetadata(slug),
    destroySeries: (slug) => api.destroySeries(slug),
    relocateSeries: (slug, newPath) => api.relocateSeries(slug, newPath),

    // Episodes
    toggleEpisode: (id) => api.toggleEpisode(id),
    getNextEpisode: (id) => api.getNextEpisode(id),
    playEpisode: (id) => api.playEpisode(id),

    // Movies
    listMovies: () => api.listMovies(),
    getMovie: (slug) => api.getMovie(slug),
    addMovies: (files) => api.addMovies(files),
    toggleMovie: (slug) => api.toggleMovie(slug),
    refreshMovieMetadata: (slug) => api.refreshMovieMetadata(slug),
    destroyMovie: (slug) => api.destroyMovie(slug),
    relocateMovie: (slug, newPath) => api.relocateMovie(slug, newPath),
    playMovie: (slug) => api.playMovie(slug),

    // Playback
    startPlayback: (filePath, startTime, prefs, options) => api.startPlayback(filePath, startTime, prefs, options),
    stopPlayback: (finalTime, finalDuration, _context) => api.stopPlayback(finalTime, finalDuration),
    setPlaybackEpisode: (id, whId) => api.setPlaybackEpisode(id, whId),
    setPlaybackMovie: (id) => api.setPlaybackMovie(id),
    seekPlayback: (time) => api.seekPlayback(time),
    reportProgress: (time, duration) => api.reportProgress(time, duration),
    getPlaybackStatus: () => api.getPlaybackStatus(),
    getPlaybackPreferences: (opts) => api.getPlaybackPreferences(opts),
    savePlaybackPreferences: (prefs) => api.savePlaybackPreferences(prefs),
    switchAudio: (index, time) => api.switchAudio(index, time),
    switchSubtitle: (index) => api.switchSubtitle(index),
    switchBitmapSubtitle: (index, time) => api.switchBitmapSubtitle(index, time),

    // VLC
    checkVlc: () => api.checkVlc(),
    openInVlc: (opts) => api.openInVlc(opts),
    openInDefault: (...args) => api.openInDefault(...args),

    // Downloads
    downloadEpisode: (arg) => api.downloadEpisode(arg),
    deleteDownloadEpisode: (arg) => api.deleteDownloadEpisode(arg),
    downloadSeason: (arg) => api.downloadSeason(arg),
    deleteDownloadSeason: (arg) => api.deleteDownloadSeason(arg),
    downloadMovie: (arg) => api.downloadMovie(arg),
    deleteDownloadMovie: (arg) => api.deleteDownloadMovie(arg),
    getDownloadStatusByFilePaths: (filePaths) => api.getDownloadStatusByFilePaths(filePaths),
    getMovieDownloadStatusByFilePath: (filePath) => api.getMovieDownloadStatusByFilePath(filePath),

    // Settings
    getSettings: () => api.getSettings(),
    setSyncFolder: (path) => api.setSyncFolder(path),
    syncNow: () => api.syncNow(),
    loadFromSync: () => api.loadFromSync(),

    // File pickers
    selectFolder: () => api.selectFolder(),
    selectFiles: () => api.selectFiles(),

    // Events (return cleanup functions)
    onVlcPlaybackEnded: (cb) => api.onVlcPlaybackEnded(cb),
    onMediaDownloadProgress: (cb) => api.onMediaDownloadProgress(cb),
    onSubtitlesReady: (cb) => api.onSubtitlesReady?.(cb) || (() => {}),

    // Updates
    checkForUpdate: () => api.checkForUpdate(),
    onUpdateAvailable: (cb) => api.onUpdateAvailable(cb),
    onDownloadProgress: (cb) => api.onDownloadProgress(cb),
    downloadUpdate: () => api.downloadUpdate(),
    installUpdate: () => api.installUpdate(),

    // Admin (server-only — pure local mode has no Rails server to admin)
    listMediaFolders: async () => null,
    addMediaFolder: async () => null,
    updateMediaFolder: async () => null,
    removeMediaFolder: async () => null,
    browseServerPath: async () => null,
    listPendingImports: async () => null,
    confirmPendingImport: async () => null,
    ignorePendingImport: async () => null,
    researchPendingImport: async () => null,
    triggerAdminScan: async () => null,
  }
}

/** Default capabilities for desktop local mode */
export const localCapabilities = {
  canPlay: true,
  canDownload: true,
  canAdd: true,
  canManage: true,
  canOpenExternal: true,
  hasNowPlaying: true,
  hasSettings: true,
  hasPlayground: true,
  canAdmin: false,
}
