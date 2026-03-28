// Database sync: copy local SQLite DB to/from a shared folder.
// Option D: dump on app close, load on app open. No periodic sync.
// Uses better-sqlite3's native .backup() for safe async backup.

const fs = require('fs')
const fsp = require('fs/promises')
const path = require('path')
const db = require('../db')
const syncConfig = require('./sync-config')

const SYNC_FILENAME = 'series_tracker.sqlite3'

function syncDbPath() {
  const folder = syncConfig.getSyncFolder()
  if (!folder) return null
  return path.join(folder, SYNC_FILENAME)
}

/**
 * Dump local DB to sync folder using better-sqlite3's native .backup().
 * Safe to call while DB is open. Returns true/false.
 */
async function dump() {
  if (!syncConfig.isEnabled()) return false

  const dst = syncDbPath()
  if (!dst) return false

  const database = db.get()
  if (!database) return false

  try {
    await database.backup(dst)
    syncConfig.setLastSyncedAt(new Date().toISOString())
    console.log(`DbSync: dumped database to ${dst}`)
    return true
  } catch (e) {
    console.warn(`DbSync: dump failed — ${e.message}`)
    return false
  }
}

/**
 * Load DB from sync folder if it's newer than local.
 * Closes DB, copies sync → local, reopens. Returns true/false.
 */
async function load() {
  if (!syncConfig.isEnabled()) return false

  const src = syncDbPath()
  const dst = db.getDbPath()
  if (!src || !fs.existsSync(src)) return false

  try {
    const [localStat, syncStat] = await Promise.all([
      fsp.stat(dst).catch(() => null),
      fsp.stat(src).catch(() => null),
    ])

    // Only load if sync copy is newer (or local doesn't exist)
    if (localStat && syncStat && syncStat.mtimeMs <= localStat.mtimeMs) {
      console.log('DbSync: local DB is current, skipping load')
      return false
    }

    // Close, copy, reopen
    db.close()
    await fsp.copyFile(src, dst)
    db.open()

    syncConfig.setLastSyncedAt(new Date().toISOString())
    console.log(`DbSync: loaded database from ${src}`)
    return true
  } catch (e) {
    console.warn(`DbSync: load failed — ${e.message}`)
    // Try to reopen DB even if copy failed
    try { db.open() } catch { /* nothing we can do */ }
    return false
  }
}

/**
 * On startup: pull newer DB from sync folder if available.
 */
async function syncOnStartup() {
  if (!syncConfig.isEnabled()) return
  await load()
}

/**
 * Sync status for Settings UI. Synchronous.
 */
function getStatus() {
  const localPath = db.getDbPath()
  const remotePath = syncDbPath()

  const localExists = fs.existsSync(localPath)
  const remoteExists = remotePath && fs.existsSync(remotePath)

  return {
    enabled: syncConfig.isEnabled(),
    sync_folder: syncConfig.getSyncFolder(),
    local_size: localExists ? fs.statSync(localPath).size : null,
    local_modified: localExists ? fs.statSync(localPath).mtime.toISOString() : null,
    sync_size: remoteExists ? fs.statSync(remotePath).size : null,
    sync_modified: remoteExists ? fs.statSync(remotePath).mtime.toISOString() : null,
    last_sync: syncConfig.getLastSyncedAt(),
  }
}

module.exports = { dump, load, syncOnStartup, getStatus }
