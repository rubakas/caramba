const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('api', {
  // Series
  listSeries: () => ipcRenderer.invoke('series:list'),
  getSeries: (slug) => ipcRenderer.invoke('series:get', slug),
  getSeriesEpisodes: (slug) => ipcRenderer.invoke('series:getEpisodes', slug),
  getSeriesSeasons: (slug) => ipcRenderer.invoke('series:getSeasons', slug),
  getResumable: (slug) => ipcRenderer.invoke('series:getResumable', slug),
  getNextUp: (slug) => ipcRenderer.invoke('series:getNextUp', slug),
  addSeries: (folderPath) => ipcRenderer.invoke('series:add', folderPath),
  scanSeries: (slug) => ipcRenderer.invoke('series:scan', slug),
  refreshSeriesMetadata: (slug) => ipcRenderer.invoke('series:refreshMetadata', slug),
  destroySeries: (slug) => ipcRenderer.invoke('series:destroy', slug),

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

  // Playback (new transcoder-based)
  startPlayback: (filePath, startTime, prefs) => ipcRenderer.invoke('playback:start', filePath, startTime, prefs),
  seekPlayback: (time) => ipcRenderer.invoke('playback:seek', time),
  stopPlayback: (finalTime, finalDuration) => ipcRenderer.invoke('playback:stop', finalTime, finalDuration),
  reportProgress: (time, duration) => ipcRenderer.invoke('playback:progress', time, duration),
  getPlaybackStatus: () => ipcRenderer.invoke('playback:status'),
  setPlaybackEpisode: (episodeId, whId) => ipcRenderer.invoke('playback:setEpisode', episodeId, whId),
  setPlaybackMovie: (movieId) => ipcRenderer.invoke('playback:setMovie', movieId),
  switchAudio: (audioStreamIndex, currentVideoTime) => ipcRenderer.invoke('playback:switchAudio', audioStreamIndex, currentVideoTime),
  switchSubtitle: (subtitleStreamIndex) => ipcRenderer.invoke('playback:switchSubtitle', subtitleStreamIndex),
  savePlaybackPreferences: (prefs) => ipcRenderer.invoke('playback:savePreferences', prefs),
  getPlaybackPreferences: (query) => ipcRenderer.invoke('playback:getPreferences', query),
  checkVlc: () => ipcRenderer.invoke('playback:checkVlc'),
  openInVlc: (opts) => ipcRenderer.invoke('playback:openInVlc', opts),
  openInDefault: (filePath) => ipcRenderer.invoke('playback:openInDefault', filePath),
  onVlcPlaybackEnded: (cb) => {
    const handler = () => cb()
    ipcRenderer.on('vlc-playback-ended', handler)
    return () => ipcRenderer.removeListener('vlc-playback-ended', handler)
  },

  // History
  listHistory: (limit) => ipcRenderer.invoke('history:list', limit),
  getHistoryStats: () => ipcRenderer.invoke('history:stats'),

  // Settings
  getSettings: () => ipcRenderer.invoke('settings:get'),
  setSyncFolder: (folder) => ipcRenderer.invoke('settings:setSyncFolder', folder),
  syncNow: () => ipcRenderer.invoke('settings:syncNow'),
  loadFromSync: () => ipcRenderer.invoke('settings:loadFromSync'),

  // Dialogs
  selectFolder: () => ipcRenderer.invoke('dialog:selectFolder'),
  selectFiles: () => ipcRenderer.invoke('dialog:selectFiles'),
})
