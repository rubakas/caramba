// Database sync: copy local SQLite DB to/from a shared folder.
// Dump on app close, load on app open.
// Uses better-sqlite3's .backup() to a local temp file, then copies to the
// sync folder via fs.copyFile. Direct SQLite backup to network filesystems
// (SMB/AFP) fails because they don't support SQLite's locking properly.

const fs = require('fs')
const fsp = require('fs/promises')
const path = require('path')
const os = require('os')
const db = require('../db')
const syncConfig = require('./sync-config')

const SYNC_FILENAME = 'series_tracker.sqlite3'

function syncDbPath() {
  const folder = syncConfig.getSyncFolder()
  if (!folder) return null
  return path.join(folder, SYNC_FILENAME)
}

/**
 * Dump local DB to sync folder.
 * Backs up to a local temp file first (SQLite backup API needs a local fs),
 * then copies to the sync folder with a regular file copy.
 * Returns { ok: true } or { ok: false, reason: string }.
 */
async function dump() {
  const folder = syncConfig.getSyncFolder()
  if (!folder) return { ok: false, reason: 'No sync folder configured.' }

  if (!fs.existsSync(folder)) {
    console.warn(`DbSync: sync folder not accessible — ${folder}`)
    return { ok: false, reason: `Sync folder not accessible: ${folder}` }
  }

  const dst = syncDbPath()
  if (!dst) return { ok: false, reason: 'Could not determine sync path.' }

  const database = db.get()
  if (!database) return { ok: false, reason: 'Database not open.' }

  const tmpFile = path.join(os.tmpdir(), `caramba-sync-${Date.now()}.sqlite3`)

  try {
    // Step 1: SQLite backup to local temp file (safe, uses SQLite locking)
    await database.backup(tmpFile)
    // Step 2: Copy temp file to sync folder (works on any filesystem)
    await fsp.copyFile(tmpFile, dst)
    syncConfig.setLastSyncedAt(new Date().toISOString())
    console.log(`DbSync: dumped database to ${dst}`)
    return { ok: true }
  } catch (e) {
    console.warn(`DbSync: dump failed — ${e.message}`)
    return { ok: false, reason: e.message }
  } finally {
    // Clean up temp file
    try { fs.unlinkSync(tmpFile) } catch {}
  }
}

/**
 * Load DB from sync folder if it's newer than local.
 * Closes DB, copies sync → local, reopens. Returns { ok: true } or { ok: false, reason: string }.
 */
async function load() {
  const folder = syncConfig.getSyncFolder()
  if (!folder) return { ok: false, reason: 'No sync folder configured.' }

  if (!fs.existsSync(folder)) {
    console.warn(`DbSync: sync folder not accessible — ${folder}`)
    return { ok: false, reason: `Sync folder not accessible: ${folder}` }
  }

  const src = syncDbPath()
  const dst = db.getDbPath()
  if (!src || !fs.existsSync(src)) return { ok: false, reason: 'No database found in sync folder.' }

  try {
    const [localStat, syncStat] = await Promise.all([
      fsp.stat(dst).catch(() => null),
      fsp.stat(src).catch(() => null),
    ])

    // Only load if sync copy is newer (or local doesn't exist)
    if (localStat && syncStat && syncStat.mtimeMs <= localStat.mtimeMs) {
      console.log('DbSync: local DB is current, skipping load')
      return { ok: false, reason: 'Local database is already up to date.' }
    }

    // Close, copy, reopen
    db.close()
    await fsp.copyFile(src, dst)
    db.open()

    syncConfig.setLastSyncedAt(new Date().toISOString())
    console.log(`DbSync: loaded database from ${src}`)
    return { ok: true }
  } catch (e) {
    console.warn(`DbSync: load failed — ${e.message}`)
    // Try to reopen DB even if copy failed
    try { db.open() } catch { /* nothing we can do */ }
    return { ok: false, reason: e.message }
  }
}

/**
 * On startup: pull newer DB from sync folder if available.
 */
async function syncOnStartup() {
  if (!syncConfig.getSyncFolder()) return
  await load()
}

/**
 * Sync status for Settings UI. Synchronous.
 */
function getStatus() {
  const localPath = db.getDbPath()
  const remotePath = syncDbPath()
  const folder = syncConfig.getSyncFolder()

  const localExists = fs.existsSync(localPath)
  const folderAccessible = !!folder && fs.existsSync(folder)
  const remoteExists = remotePath && fs.existsSync(remotePath)

  return {
    enabled: syncConfig.isEnabled(),
    sync_folder: folder,
    folder_accessible: folderAccessible,
    local_size: localExists ? fs.statSync(localPath).size : null,
    local_modified: localExists ? fs.statSync(localPath).mtime.toISOString() : null,
    sync_size: remoteExists ? fs.statSync(remotePath).size : null,
    sync_modified: remoteExists ? fs.statSync(remotePath).mtime.toISOString() : null,
    last_sync: syncConfig.getLastSyncedAt(),
  }
}

module.exports = { dump, load, syncOnStartup, getStatus }
