const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('api', {
  // Series
  listSeries: () => ipcRenderer.invoke('series:list'),
  getSeries: (slug) => ipcRenderer.invoke('series:get', slug),
  getSeriesShow: (slug) => ipcRenderer.invoke('series:show', slug),
  getSeriesEpisodes: (slug) => ipcRenderer.invoke('series:getEpisodes', slug),
  getSeriesSeasons: (slug) => ipcRenderer.invoke('series:getSeasons', slug),
  getContinue: (slug) => ipcRenderer.invoke('series:getContinue', slug),
  addSeries: (folderPath) => ipcRenderer.invoke('series:add', folderPath),
  scanSeries: (slug) => ipcRenderer.invoke('series:scan', slug),
  refreshSeriesMetadata: (slug) => ipcRenderer.invoke('series:refreshMetadata', slug),
  destroySeries: (slug) => ipcRenderer.invoke('series:destroy', slug),
  relocateSeries: (slug, newPath) => ipcRenderer.invoke('series:relocate', slug, newPath),

  // Episodes
  playEpisode: (episodeId) => ipcRenderer.invoke('episodes:play', episodeId),
  toggleEpisode: (episodeId) => ipcRenderer.invoke('episodes:toggle', episodeId),
  getNextEpisode: (episodeId) => ipcRenderer.invoke('episodes:getNext', episodeId),

  // Movies
  listMovies: () => ipcRenderer.invoke('movies:list'),
  getMovie: (slug) => ipcRenderer.invoke('movies:get', slug),
  addMovies: (filePaths) => ipcRenderer.invoke('movies:add', filePaths),
  playMovie: (slug) => ipcRenderer.invoke('movies:play', slug),
  toggleMovie: (slug) => ipcRenderer.invoke('movies:toggle', slug),
  refreshMovieMetadata: (slug) => ipcRenderer.invoke('movies:refreshMetadata', slug),
  destroyMovie: (slug) => ipcRenderer.invoke('movies:destroy', slug),
  relocateMovie: (slug, newPath) => ipcRenderer.invoke('movies:relocate', slug, newPath),

  // Playback (new transcoder-based)
  startPlayback: (filePath, startTime, prefs, options) => ipcRenderer.invoke('playback:start', filePath, startTime, prefs, options),
  seekPlayback: (time) => ipcRenderer.invoke('playback:seek', time),
  stopPlayback: (finalTime, finalDuration) => ipcRenderer.invoke('playback:stop', finalTime, finalDuration),
  reportProgress: (time, duration) => ipcRenderer.invoke('playback:progress', time, duration),
  getPlaybackStatus: () => ipcRenderer.invoke('playback:status'),
  setPlaybackEpisode: (episodeId, whId) => ipcRenderer.invoke('playback:setEpisode', episodeId, whId),
  setPlaybackMovie: (movieId) => ipcRenderer.invoke('playback:setMovie', movieId),
  switchAudio: (audioStreamIndex, currentVideoTime) => ipcRenderer.invoke('playback:switchAudio', audioStreamIndex, currentVideoTime),
  switchSubtitle: (subtitleStreamIndex) => ipcRenderer.invoke('playback:switchSubtitle', subtitleStreamIndex),
  switchBitmapSubtitle: (subtitleStreamIndex, currentVideoTime) => ipcRenderer.invoke('playback:switchBitmapSubtitle', subtitleStreamIndex, currentVideoTime),
  savePlaybackPreferences: (prefs) => ipcRenderer.invoke('playback:savePreferences', prefs),
  getPlaybackPreferences: (query) => ipcRenderer.invoke('playback:getPreferences', query),
  checkVlc: () => ipcRenderer.invoke('playback:checkVlc'),
  openInVlc: (opts) => ipcRenderer.invoke('playback:openInVlc', opts),
  openInDefault: (filePath, episodeId, movieId) => ipcRenderer.invoke('playback:openInDefault', filePath, episodeId, movieId),
  onVlcPlaybackEnded: (cb) => {
    const handler = () => cb()
    ipcRenderer.on('vlc-playback-ended', handler)
    return () => ipcRenderer.removeListener('vlc-playback-ended', handler)
  },
  onSubtitlesReady: (cb) => {
    const handler = (_e, data) => cb(data)
    ipcRenderer.on('playback:subtitles-ready', handler)
    return () => ipcRenderer.removeListener('playback:subtitles-ready', handler)
  },

  // Settings
  getSettings: () => ipcRenderer.invoke('settings:get'),
  setSyncFolder: (folder) => ipcRenderer.invoke('settings:setSyncFolder', folder),
  syncNow: () => ipcRenderer.invoke('settings:syncNow'),
  loadFromSync: () => ipcRenderer.invoke('settings:loadFromSync'),
  getApiMode: () => ipcRenderer.invoke('settings:getApiMode'),
  setApiMode: (opts) => ipcRenderer.invoke('settings:setApiMode', opts),
  fileExists: (path) => ipcRenderer.invoke('fs:exists', path),

  // Dialogs
  selectFolder: () => ipcRenderer.invoke('dialog:selectFolder'),
  selectFiles: () => ipcRenderer.invoke('dialog:selectFiles'),

  // Server discovery
  discoverServers: () => ipcRenderer.invoke('discovery:scan'),

  // Updater
  checkForUpdate: () => ipcRenderer.invoke('updater:check'),
  downloadUpdate: () => ipcRenderer.invoke('updater:download'),
  installUpdate: () => ipcRenderer.invoke('updater:install'),
  onUpdateAvailable: (cb) => {
    const handler = (_e, info) => cb(info)
    ipcRenderer.on('updater:update-available', handler)
    return () => ipcRenderer.removeListener('updater:update-available', handler)
  },
  onDownloadProgress: (cb) => {
    const handler = (_e, progress) => cb(progress)
    ipcRenderer.on('updater:download-progress', handler)
    return () => ipcRenderer.removeListener('updater:download-progress', handler)
  },

  // Dev-only: save glass config (playground → glass.json)
  saveGlassConfig: (config) => ipcRenderer.invoke('dev:saveGlassConfig', config),

  // Downloads (offline media cache)
  downloadEpisode: (arg) => ipcRenderer.invoke('downloads:episode', arg),
  downloadSeason: (arg) => ipcRenderer.invoke('downloads:season', arg),
  downloadMovie: (arg) => ipcRenderer.invoke('downloads:movie', arg),
  cancelDownload: (downloadId) => ipcRenderer.invoke('downloads:cancel', downloadId),
  deleteDownloadEpisode: (arg) => ipcRenderer.invoke('downloads:deleteEpisode', arg),
  deleteDownloadSeason: (arg) => ipcRenderer.invoke('downloads:deleteSeason', arg),
  deleteDownloadMovie: (arg) => ipcRenderer.invoke('downloads:deleteMovie', arg),
  listDownloads: () => ipcRenderer.invoke('downloads:list'),
  getStorageInfo: () => ipcRenderer.invoke('downloads:storageInfo'),
  getDownloadStatusByFilePaths: (filePaths) => ipcRenderer.invoke('downloads:statusByFilePaths', filePaths),
  getMovieDownloadStatusByFilePath: (filePath) => ipcRenderer.invoke('downloads:movieStatusByFilePath', filePath),
  onMediaDownloadProgress: (cb) => {
    const handler = (_e, data) => cb(data)
    ipcRenderer.on('downloads:progress', handler)
    return () => ipcRenderer.removeListener('downloads:progress', handler)
  },
})
