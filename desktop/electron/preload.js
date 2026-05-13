const { contextBridge, ipcRenderer } = require('electron')

// The desktop renderer talks to the Rails server over HTTP for everything
// data-related. The bridge below is just the electron-only surface:
// dialogs, downloads, external VLC, mDNS, updater, prefs.
contextBridge.exposeInMainWorld('api', {
  // Server URL + app preferences
  getServerConfig: () => ipcRenderer.invoke('settings:getServerConfig'),
  setServerConfig: (cfg) => ipcRenderer.invoke('settings:setServerConfig', cfg),
  getPreferences: () => ipcRenderer.invoke('settings:getPreferences'),
  setPreferences: (patch) => ipcRenderer.invoke('settings:setPreferences', patch),

  // Folder picker (downloads destination)
  selectFolder: () => ipcRenderer.invoke('dialog:selectFolder'),

  // mDNS discovery
  discoverServers: () => ipcRenderer.invoke('discovery:scan'),

  // External VLC subprocess
  checkVlc: () => ipcRenderer.invoke('vlc:checkInstalled'),
  openInVlc: (payload) => ipcRenderer.invoke('vlc:openInVlc', payload),
  openInDefault: (payload) => ipcRenderer.invoke('vlc:openInDefault', payload),
  getPlaybackStatus: () => ipcRenderer.invoke('vlc:status'),
  onVlcPlaybackEnded: (cb) => {
    const handler = () => cb()
    ipcRenderer.on('vlc-playback-ended', handler)
    return () => ipcRenderer.removeListener('vlc-playback-ended', handler)
  },

  // External VLC library control (NowPlaying scrubber)
  vlcStatus: () => ipcRenderer.invoke('vlc:libStatus'),
  vlcPause: () => ipcRenderer.invoke('vlc:libPause'),
  vlcResume: () => ipcRenderer.invoke('vlc:libResume'),
  vlcStop: () => ipcRenderer.invoke('vlc:libStop'),
  vlcSeek: (seconds) => ipcRenderer.invoke('vlc:libSeek', seconds),
  vlcSetVolume: (level) => ipcRenderer.invoke('vlc:libVolume', level),

  // Downloads
  downloadEpisode: (payload) => ipcRenderer.invoke('downloads:episode', payload),
  deleteDownloadEpisode: (payload) => ipcRenderer.invoke('downloads:deleteEpisode', payload),
  downloadMovie: (payload) => ipcRenderer.invoke('downloads:movie', payload),
  deleteDownloadMovie: (payload) => ipcRenderer.invoke('downloads:deleteMovie', payload),
  cancelDownload: (payload) => ipcRenderer.invoke('downloads:cancel', payload),
  getDownloadStatus: (payload) => ipcRenderer.invoke('downloads:status', payload),
  listDownloads: () => ipcRenderer.invoke('downloads:list'),
  onMediaDownloadProgress: (cb) => {
    const handler = (_e, data) => cb(data)
    ipcRenderer.on('downloads:progress', handler)
    return () => ipcRenderer.removeListener('downloads:progress', handler)
  },

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

  // Dev-only: save glass config to ui/config/glass.json (Playground page)
  saveGlassConfig: (config) => ipcRenderer.invoke('dev:saveGlassConfig', config),
})
