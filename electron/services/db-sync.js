// Database sync: copy local SQLite DB to/from a shared folder.
// Uses sqlite3 CLI .backup for safe copy while DB is open.

const { execSync } = require('child_process')
const fs = require('fs')
const path = require('path')
const db = require('../db')
const syncConfig = require('./sync-config')

const SYNC_FILENAME = 'series_tracker.sqlite3'
const SYNC_INTERVAL = 30000 // 30 seconds

let syncTimer = null

function syncDbPath() {
  const folder = syncConfig.getSyncFolder()
  if (!folder) return null
  return path.join(folder, SYNC_FILENAME)
}

function dump() {
  if (!syncConfig.isEnabled()) return false

  const src = db.getDbPath()
  const dst = syncDbPath()
  if (!dst || !fs.existsSync(src)) return false

  const tmp = dst + '.tmp'
  try {
    execSync(`sqlite3 "${src}" ".backup '${tmp}'"`, { timeout: 10000 })
    if (fs.existsSync(tmp) && fs.statSync(tmp).size > 0) {
      fs.renameSync(tmp, dst)
      syncConfig.setLastSyncedAt(new Date().toISOString())
      console.log(`DbSync: dumped database to ${dst}`)
      return true
    }
    try { fs.unlinkSync(tmp) } catch { /* ignore */ }
    console.warn('DbSync: backup produced empty file')
    return false
  } catch (e) {
    try { fs.unlinkSync(tmp) } catch { /* ignore */ }
    console.warn(`DbSync: dump failed — ${e.message}`)
    return false
  }
}

function load() {
  if (!syncConfig.isEnabled()) return false

  const src = syncDbPath()
  const dst = db.getDbPath()
  if (!src || !fs.existsSync(src)) return false

  try {
    // Close current DB connection
    db.close()

    // Backup current local DB
    const backup = dst + '.backup'
    if (fs.existsSync(dst)) fs.copyFileSync(dst, backup)

    // Copy sync DB to local
    fs.copyFileSync(src, dst)

    // Reopen DB (triggers migration)
    db.open()

    syncConfig.setLastSyncedAt(new Date().toISOString())
    console.log(`DbSync: loaded database from ${src}`)

    // Clean up backup
    try { fs.unlinkSync(backup) } catch { /* ignore */ }
    return true
  } catch (e) {
    console.warn(`DbSync: load failed — ${e.message}`)
    // Try to restore
    try {
      const backup = dst + '.backup'
      if (fs.existsSync(backup)) {
        fs.copyFileSync(backup, dst)
        db.open()
      }
    } catch { /* nothing we can do */ }
    return false
  }
}

function syncOnStartup() {
  if (!syncConfig.isEnabled()) return

  const localPath = db.getDbPath()
  const remotePath = syncDbPath()
  if (!remotePath) return

  const localMtime = fs.existsSync(localPath) ? fs.statSync(localPath).mtimeMs : 0
  const remoteMtime = fs.existsSync(remotePath) ? fs.statSync(remotePath).mtimeMs : 0

  if (fs.existsSync(remotePath) && remoteMtime > localMtime) {
    console.log('DbSync: sync folder has newer DB, loading...')
    load()
  } else if (fs.existsSync(localPath)) {
    console.log('DbSync: local DB is current, dumping to sync folder...')
    dump()
  }
}

function startPeriodicSync() {
  stopPeriodicSync()
  if (!syncConfig.isEnabled()) return

  syncTimer = setInterval(() => {
    try {
      const localPath = db.getDbPath()
      const remotePath = syncDbPath()
      if (!remotePath) return

      const localMtime = fs.existsSync(localPath) ? fs.statSync(localPath).mtimeMs : 0
      const remoteMtime = fs.existsSync(remotePath) ? fs.statSync(remotePath).mtimeMs : 0

      if (fs.existsSync(remotePath) && remoteMtime > localMtime + 2000) {
        console.log('DbSync: sync folder has newer DB, loading...')
        load()
      } else {
        dump()
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
