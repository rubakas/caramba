// Tiny JSON-backed preferences store for the desktop app.
//
// Replaces the SQLite + sync-config + api-config trio with a single JSON
// file under `userData/preferences.json`. Keeps the surface narrow: server
// URL, theme, downloads folder. Per-show / per-movie playback preferences
// live on the server now (via /api/playback/preferences). Codec/transcode
// decisions are driven by the DeviceProfile sent on each playback start —
// no manual toggle. The video engine is chosen at runtime based on
// capability detection (libmpv when the native module loads, hls.js
// otherwise) — not a user preference.

const fs = require('fs')
const path = require('path')
const { app } = require('electron')

const FILENAME = 'preferences.json'

const DEFAULTS = {
  serverUrl: null,
  theme: 'dark',
  downloadsFolder: null,     // null = userData/downloads
}

let cache = null
let filePath = null

function ensureLoaded() {
  if (cache) return cache
  if (!filePath) filePath = path.join(app.getPath('userData'), FILENAME)
  try {
    if (fs.existsSync(filePath)) {
      const raw = fs.readFileSync(filePath, 'utf-8')
      cache = { ...DEFAULTS, ...JSON.parse(raw) }
      return cache
    }
  } catch (err) {
    console.warn('[preferences] read failed, starting fresh:', err.message)
  }
  cache = { ...DEFAULTS }
  return cache
}

function persist() {
  try {
    if (!filePath) filePath = path.join(app.getPath('userData'), FILENAME)
    fs.mkdirSync(path.dirname(filePath), { recursive: true })
    const tmp = filePath + '.tmp'
    fs.writeFileSync(tmp, JSON.stringify(cache, null, 2), 'utf-8')
    fs.renameSync(tmp, filePath)
  } catch (err) {
    console.warn('[preferences] write failed:', err.message)
  }
}

function getAll() {
  return { ...ensureLoaded() }
}

function get(key) {
  return ensureLoaded()[key]
}

function set(patch) {
  const cur = ensureLoaded()
  cache = { ...cur, ...patch }
  persist()
  return cache
}

function downloadsFolder() {
  const cur = ensureLoaded()
  if (cur.downloadsFolder) return cur.downloadsFolder
  return path.join(app.getPath('userData'), 'downloads')
}

module.exports = {
  getAll,
  get,
  set,
  downloadsFolder,
}
