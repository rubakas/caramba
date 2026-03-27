// Database sync: copy local SQLite DB to/from a shared folder.
// Uses sqlite3 CLI .backup for safe copy while DB is open.
// All operations are ASYNC to avoid blocking the Electron main process.

const { execFile } = require('child_process')
const fs = require('fs')
const fsp = require('fs/promises')
const path = require('path')
const db = require('../db')
const syncConfig = require('./sync-config')

const SYNC_FILENAME = 'series_tracker.sqlite3'
const SYNC_INTERVAL = 30000 // 30 seconds

let syncTimer = null
let syncInProgress = false // guard against overlapping syncs

function syncDbPath() {
  const folder = syncConfig.getSyncFolder()
  if (!folder) return null
  return path.join(folder, SYNC_FILENAME)
}

/**
 * Dump local DB to sync folder using sqlite3 .backup (async, non-blocking).
 */
async function dump() {
  if (!syncConfig.isEnabled()) return false
  if (syncInProgress) return false

  const src = db.getDbPath()
  const dst = syncDbPath()
  if (!dst || !fs.existsSync(src)) return false

  const tmp = dst + '.tmp'
  syncInProgress = true

  try {
    // Run sqlite3 .backup asynchronously
    await new Promise((resolve, reject) => {
      execFile('sqlite3', [src, `.backup '${tmp}'`], { timeout: 10000 }, (err) => {
        if (err) reject(err)
        else resolve()
      })
    })

    // Verify the backup produced a valid file
    const stat = await fsp.stat(tmp).catch(() => null)
    if (stat && stat.size > 0) {
      await fsp.rename(tmp, dst)
      syncConfig.setLastSyncedAt(new Date().toISOString())
      console.log(`DbSync: dumped database to ${dst}`)
      return true
    }

    await fsp.unlink(tmp).catch(() => {})
    console.warn('DbSync: backup produced empty file')
    return false
  } catch (e) {
    await fsp.unlink(tmp).catch(() => {})
    console.warn(`DbSync: dump failed — ${e.message}`)
    return false
  } finally {
    syncInProgress = false
  }
}

/**
 * Load DB from sync folder, replacing local DB (async, non-blocking).
 */
async function load() {
  if (!syncConfig.isEnabled()) return false
  if (syncInProgress) return false

  const src = syncDbPath()
  const dst = db.getDbPath()
  if (!src || !fs.existsSync(src)) return false

  syncInProgress = true

  try {
    // Close current DB connection
    db.close()

    // Backup current local DB
    const backup = dst + '.backup'
    if (fs.existsSync(dst)) {
      await fsp.copyFile(dst, backup)
    }

    // Copy sync DB to local
    await fsp.copyFile(src, dst)

    // Reopen DB (triggers migration)
    db.open()

    syncConfig.setLastSyncedAt(new Date().toISOString())
    console.log(`DbSync: loaded database from ${src}`)

    // Clean up backup
    await fsp.unlink(backup).catch(() => {})
    return true
  } catch (e) {
    console.warn(`DbSync: load failed — ${e.message}`)
    // Try to restore from backup
    try {
      const backup = dst + '.backup'
      if (fs.existsSync(backup)) {
        await fsp.copyFile(backup, dst)
        db.open()
      }
    } catch { /* nothing we can do */ }
    return false
  } finally {
    syncInProgress = false
  }
}

/**
 * On startup, check if sync folder has a newer DB and load it,
 * or dump local DB if it's current. Runs async in background — does NOT block app startup.
 */
async function syncOnStartup() {
  if (!syncConfig.isEnabled()) return

  const localPath = db.getDbPath()
  const remotePath = syncDbPath()
  if (!remotePath) return

  try {
    const [localStat, remoteStat] = await Promise.all([
      fsp.stat(localPath).catch(() => null),
      fsp.stat(remotePath).catch(() => null),
    ])

    const localMtime = localStat ? localStat.mtimeMs : 0
    const remoteMtime = remoteStat ? remoteStat.mtimeMs : 0

    if (remoteStat && remoteMtime > localMtime) {
      console.log('DbSync: sync folder has newer DB, loading...')
      await load()
    } else if (localStat) {
      console.log('DbSync: local DB is current, dumping to sync folder...')
      await dump()
    }
  } catch (e) {
    console.warn(`DbSync: startup sync error — ${e.message}`)
  }
}

function startPeriodicSync() {
  stopPeriodicSync()
  if (!syncConfig.isEnabled()) return

  syncTimer = setInterval(async () => {
    try {
      const localPath = db.getDbPath()
      const remotePath = syncDbPath()
      if (!remotePath) return

      const [localStat, remoteStat] = await Promise.all([
        fsp.stat(localPath).catch(() => null),
        fsp.stat(remotePath).catch(() => null),
      ])

      const localMtime = localStat ? localStat.mtimeMs : 0
      const remoteMtime = remoteStat ? remoteStat.mtimeMs : 0

      if (remoteStat && remoteMtime > localMtime + 2000) {
        console.log('DbSync: sync folder has newer DB, loading...')
        await load()
      } else {
        await dump()
      }
    } catch (e) {
      console.warn(`DbSync: periodic sync error — ${e.message}`)
    }
  }, SYNC_INTERVAL)

  console.log(`DbSync: periodic sync started (every ${SYNC_INTERVAL / 1000}s)`)
}

function stopPeriodicSync() {
  if (syncTimer) {
    clearInterval(syncTimer)
    syncTimer = null
    console.log('DbSync: periodic sync stopped')
  }
}

function isSyncRunning() {
  return syncTimer != null
}

function getStatus() {
  const localPath = db.getDbPath()
  const remotePath = syncDbPath()

  return {
    enabled: syncConfig.isEnabled(),
    sync_folder: syncConfig.getSyncFolder(),
    local_size: fs.existsSync(localPath) ? fs.statSync(localPath).size : null,
    local_modified: fs.existsSync(localPath) ? fs.statSync(localPath).mtime.toISOString() : null,
    sync_size: remotePath && fs.existsSync(remotePath) ? fs.statSync(remotePath).size : null,
    sync_modified: remotePath && fs.existsSync(remotePath) ? fs.statSync(remotePath).mtime.toISOString() : null,
    last_sync: syncConfig.getLastSyncedAt(),
    sync_running: isSyncRunning(),
  }
}

module.exports = { dump, load, syncOnStartup, startPeriodicSync, stopPeriodicSync, isSyncRunning, getStatus }
