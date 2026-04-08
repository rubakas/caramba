// IPC handlers for settings + DB sync

const { ipcMain } = require('electron')
const { execSync } = require('child_process')
const syncConfig = require('../services/sync-config')
const dbSync = require('../services/db-sync')
const fs = require('fs')
const path = require('path')

/**
 * Check if a path is on a network volume (SMB/AFP/NFS mount).
 */
function isNetworkVolume(folderPath) {
  if (!folderPath || !folderPath.startsWith('/Volumes/')) return false
  try {
    const mountOutput = execSync('mount', { encoding: 'utf-8' })
    // Find the longest matching mount point for this path
    for (const line of mountOutput.split('\n')) {
      const match = line.match(/on (\/Volumes\/[^\s]+) \((\w+),/)
      if (!match) continue
      const mountPoint = match[1]
      const fsType = match[2]
      if (folderPath.startsWith(mountPoint) && ['smbfs', 'afpfs', 'nfs', 'webdav'].includes(fsType)) {
        return true
      }
    }
  } catch {}
  return false
}

function register() {
  ipcMain.handle('settings:get', () => {
    return {
      sync_folder: syncConfig.getSyncFolder(),
      status: dbSync.getStatus(),
    }
  })

  ipcMain.handle('settings:setSyncFolder', async (_e, folder) => {
    if (folder && !fs.existsSync(folder)) {
      return { error: `Folder does not exist: ${folder}` }
    }

    const networkWarning = folder && isNetworkVolume(folder)
      ? ' Note: this is a network share — sync will only work while the remote volume is mounted.'
      : ''

    syncConfig.setSyncFolder(folder || null)

    if (folder) {
      // If a synced DB already exists in the folder, load it instead of overwriting
      const syncPath = path.join(folder, 'series_tracker.sqlite3')
      if (fs.existsSync(syncPath) && fs.statSync(syncPath).size > 0) {
        await dbSync.load()
        return { success: true, message: 'Found existing database in sync folder — loaded it.' + networkWarning }
      }
      await dbSync.dump()
      return { success: true, message: 'Sync folder set. Database syncs on app open/close.' + networkWarning }
    } else {
      return { success: true, message: 'Sync disabled.' }
    }
  })

  ipcMain.handle('settings:syncNow', async () => {
    const folder = syncConfig.getSyncFolder()
    if (!folder) {
      return { error: 'No sync folder configured.' }
    }
    if (!fs.existsSync(folder)) {
      return { error: `Sync folder not accessible: ${folder}. Is the volume mounted?` }
    }
    const result = await dbSync.dump()
    return result.ok
      ? { success: true, message: 'Database synced to folder.' }
      : { error: `Sync failed: ${result.reason}` }
  })

  ipcMain.handle('settings:loadFromSync', async () => {
    const folder = syncConfig.getSyncFolder()
    if (!folder) {
      return { error: 'No sync folder configured.' }
    }
    if (!fs.existsSync(folder)) {
      return { error: `Sync folder not accessible: ${folder}. Is the volume mounted?` }
    }
    const syncPath = path.join(folder, 'series_tracker.sqlite3')
    if (!fs.existsSync(syncPath)) {
      return { error: 'No database found in sync folder.' }
    }
    const result = await dbSync.load()
    return result.ok
      ? { success: true, message: 'Database loaded from sync folder.' }
      : { error: `Load failed: ${result.reason}` }
  })
}

module.exports = { register }
