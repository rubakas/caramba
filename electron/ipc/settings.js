// IPC handlers for settings + DB sync

const { ipcMain } = require('electron')
const syncConfig = require('../services/sync-config')
const dbSync = require('../services/db-sync')
const fs = require('fs')
const path = require('path')

function register() {
  ipcMain.handle('settings:get', () => {
    return {
      sync_folder: syncConfig.getSyncFolder(),
      status: dbSync.getStatus(),
    }
  })

  ipcMain.handle('settings:setSyncFolder', (_e, folder) => {
    if (folder && !fs.existsSync(folder)) {
      return { error: `Folder does not exist: ${folder}` }
    }

    syncConfig.setSyncFolder(folder || null)

    if (folder) {
      // If a synced DB already exists in the folder, load it instead of overwriting
      const syncPath = path.join(folder, 'series_tracker.sqlite3')
      if (fs.existsSync(syncPath) && fs.statSync(syncPath).size > 0) {
        dbSync.load()
        dbSync.startPeriodicSync()
        return { success: true, message: 'Found existing database in sync folder — loaded it.' }
      }
      dbSync.dump()
      dbSync.startPeriodicSync()
      return { success: true, message: 'Sync folder set. Database will sync every 30 seconds.' }
    } else {
      dbSync.stopPeriodicSync()
      return { success: true, message: 'Sync disabled.' }
    }
  })

  ipcMain.handle('settings:syncNow', () => {
    if (!syncConfig.isEnabled()) {
      return { error: 'No sync folder configured.' }
    }
    const ok = dbSync.dump()
    return ok ? { success: true, message: 'Database synced to folder.' } : { error: 'Sync failed.' }
  })

  ipcMain.handle('settings:loadFromSync', () => {
    if (!syncConfig.isEnabled()) {
      return { error: 'No sync folder configured.' }
    }
    const syncPath = path.join(syncConfig.getSyncFolder(), 'series_tracker.sqlite3')
    if (!fs.existsSync(syncPath)) {
      return { error: 'No database found in sync folder.' }
    }
    const ok = dbSync.load()
    return ok ? { success: true, message: 'Database loaded from sync folder.' } : { error: 'Load failed.' }
  })
}

module.exports = { register }
