const { ipcMain } = require('electron')
const updater = require('../services/updater')

// Stored after a successful download — never accepted from the renderer.
let pendingInstallPath = null
// Cached from the startup check. undefined = not checked yet, null = checked/no update.
let pendingUpdateInfo = undefined

function setPendingInfo(info) {
  pendingUpdateInfo = info
}

function register(mainWindow) {
  ipcMain.handle('updater:check', async () => {
    try {
      // Return cached result if the startup check already ran
      if (pendingUpdateInfo !== undefined) return pendingUpdateInfo
      const info = await updater.checkForUpdate()
      pendingUpdateInfo = info
      return info
    } catch (err) {
      return { error: err.message }
    }
  })

  ipcMain.handle('updater:download', async () => {
    try {
      // Use cached info from startup check; fall back to a fresh check if needed.
      const info = pendingUpdateInfo !== undefined ? pendingUpdateInfo : await updater.checkForUpdate()
      if (!info) return { error: 'No update available' }

      // Simulation path — skip the actual download.
      if (!info.assetUrl) {
        pendingInstallPath = '__simulated__'
        return { ok: true }
      }

      pendingInstallPath = await updater.downloadUpdate(info.assetUrl, (progress) => {
        if (mainWindow && !mainWindow.isDestroyed()) {
          mainWindow.webContents.send('updater:download-progress', progress)
        }
      }, info.sha256 || null)

      return { ok: true }
    } catch (err) {
      return { error: err.message }
    }
  })

  // filePath is NOT accepted from the renderer — we use the path stored after download.
  ipcMain.handle('updater:install', async () => {
    if (!pendingInstallPath) return { error: 'No update downloaded' }
    if (pendingInstallPath === '__simulated__') {
      console.log('Updater: simulated install — would relaunch here')
      return { ok: true }
    }
    try {
      await updater.installUpdate(pendingInstallPath)
      // installUpdate calls app.quit() — we never reach here.
    } catch (err) {
      return { error: err.message }
    }
  })
}

module.exports = { register, setPendingInfo }
