// IPC handlers for desktop settings — server URL + user preferences.
// Backed by a single JSON file in userData (see services/preferences.js).

const { ipcMain } = require('electron')
const preferences = require('../services/preferences')

function register() {
  // Server config (URL is the only required setting; the renderer probes
  // /api/health on bootstrap to confirm it's reachable).
  ipcMain.handle('settings:getServerConfig', () => {
    return { serverUrl: preferences.get('serverUrl') || null }
  })

  ipcMain.handle('settings:setServerConfig', (_e, { serverUrl } = {}) => {
    if (serverUrl !== undefined && serverUrl !== null) {
      try { new URL(serverUrl) } catch { return { error: 'Invalid URL format.' } }
      preferences.set({ serverUrl: String(serverUrl).replace(/\/+$/, '') })
    } else if (serverUrl === null) {
      preferences.set({ serverUrl: null })
    }
    return { ok: true, serverUrl: preferences.get('serverUrl') }
  })

  // App preferences (theme, player engine, downloads folder, force-transcode).
  ipcMain.handle('settings:getPreferences', () => {
    const all = preferences.getAll()
    return {
      theme: all.theme,
      playerEngine: all.playerEngine,
      downloadsFolder: preferences.downloadsFolder(),
      forceTranscode: !!all.forceTranscode,
    }
  })

  ipcMain.handle('settings:setPreferences', (_e, patch = {}) => {
    const allowed = {}
    if (patch.theme !== undefined) allowed.theme = patch.theme
    if (patch.playerEngine !== undefined) allowed.playerEngine = patch.playerEngine
    if (patch.downloadsFolder !== undefined) allowed.downloadsFolder = patch.downloadsFolder
    if (patch.forceTranscode !== undefined) allowed.forceTranscode = !!patch.forceTranscode
    preferences.set(allowed)
    return { ok: true }
  })
}

module.exports = { register }
