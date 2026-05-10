// IPC handlers for offline downloads.
//
// The renderer tells us "download episode N" or "download movie SLUG"; we
// stream the server's HLS file URL to disk under the user-configured
// downloads folder. State is held in memory (no SQLite) — on launch we
// scan the folder so previously completed downloads are recognised.

const { ipcMain, BrowserWindow } = require('electron')
const fs = require('fs')
const path = require('path')
const https = require('https')
const http = require('http')
const preferences = require('../services/preferences')

// In-memory state keyed by `episode:<id>` or `movie:<slug>`.
//   { status: 'downloading'|'complete'|'failed',
//     progress: 0..1,
//     dest: absolute file path,
//     abort: AbortController | null }
const state = new Map()

function keyFor({ episodeId, movieSlug }) {
  if (episodeId) return `episode:${episodeId}`
  if (movieSlug) return `movie:${movieSlug}`
  return null
}

function downloadsRoot() {
  const root = preferences.downloadsFolder()
  fs.mkdirSync(path.join(root, 'episodes'), { recursive: true })
  fs.mkdirSync(path.join(root, 'movies'), { recursive: true })
  return root
}

function safeFilename(name) {
  return String(name || '').replace(/[^a-zA-Z0-9._-]/g, '_').substring(0, 120) || 'untitled'
}

function buildDest(kind, label, originalName) {
  const root = downloadsRoot()
  const dir = path.join(root, kind === 'episode' ? 'episodes' : 'movies')
  const ext = path.extname(originalName || '') || '.mkv'
  const base = path.basename(originalName || '', ext)
  return path.join(dir, `${safeFilename(label)}_${safeFilename(base)}${ext}`)
}

// On startup, scan the downloads folder and populate `state` with any
// existing files. Files are matched by the leading `<id>_…` segment in the
// name we wrote at download time. We only need a coarse "is this episode
// already downloaded?" signal — paths are inferred lazily on demand.
function scanDownloadsFolder() {
  const root = downloadsRoot()
  for (const kind of ['episodes', 'movies']) {
    const dir = path.join(root, kind)
    let entries = []
    try { entries = fs.readdirSync(dir) } catch { continue }
    for (const fname of entries) {
      const m = fname.match(/^([^_]+)_/)
      if (!m) continue
      const label = m[1]
      const key = kind === 'episodes' ? `episode:${label}` : `movie:${label}`
      if (state.has(key)) continue
      state.set(key, {
        status: 'complete',
        progress: 1,
        dest: path.join(dir, fname),
        abort: null,
      })
    }
  }
}

function broadcastProgress(key, status, progress) {
  for (const win of BrowserWindow.getAllWindows()) {
    if (!win.isDestroyed()) {
      win.webContents.send('downloads:progress', { key, status, progress })
    }
  }
}

function streamToFile(url, dest, signal, onProgress) {
  return new Promise((resolve, reject) => {
    const parsed = new URL(url)
    const lib = parsed.protocol === 'https:' ? https : http
    const req = lib.get(url, (res) => {
      if (res.statusCode === 301 || res.statusCode === 302) {
        res.resume()
        return streamToFile(res.headers.location, dest, signal, onProgress).then(resolve, reject)
      }
      if (res.statusCode !== 200) {
        return reject(new Error(`Server returned ${res.statusCode}`))
      }
      const total = parseInt(res.headers['content-length'], 10) || 0
      const out = fs.createWriteStream(dest)
      let copied = 0
      let lastPct = -1
      const cancel = () => {
        req.destroy()
        res.destroy()
        out.destroy()
        try { fs.unlinkSync(dest) } catch {}
      }
      signal.addEventListener('abort', cancel, { once: true })
      res.on('data', (chunk) => {
        copied += chunk.length
        if (total > 0) {
          const pct = copied / total
          const rounded = Math.floor(pct * 100)
          if (rounded > lastPct) { lastPct = rounded; onProgress(pct) }
        }
      })
      res.on('error', err => { try { out.destroy() } catch {} ; try { fs.unlinkSync(dest) } catch {} ; reject(err) })
      out.on('error', err => { try { res.destroy() } catch {} ; try { fs.unlinkSync(dest) } catch {} ; reject(err) })
      out.on('finish', () => signal.aborted ? reject(new Error('Download cancelled')) : resolve(copied))
      res.pipe(out)
    })
    req.on('error', err => {
      try { fs.unlinkSync(dest) } catch {}
      reject(err)
    })
  })
}

async function startDownload(key, kind, payload) {
  const { url, label, originalName } = payload
  if (!url) return { error: 'No download URL' }

  // If already complete-on-disk, return success immediately.
  const existing = state.get(key)
  if (existing && existing.status === 'complete' && fs.existsSync(existing.dest)) {
    return { ok: true, status: 'complete', dest: existing.dest }
  }

  const dest = buildDest(kind, label, originalName)
  const ac = new AbortController()
  state.set(key, { status: 'downloading', progress: 0, dest, abort: ac })
  broadcastProgress(key, 'downloading', 0)

  try {
    await streamToFile(url, dest, ac.signal, pct => {
      const cur = state.get(key)
      if (!cur) return
      cur.progress = pct
      broadcastProgress(key, 'downloading', pct)
    })
    state.set(key, { status: 'complete', progress: 1, dest, abort: null })
    broadcastProgress(key, 'complete', 1)
    return { ok: true, status: 'complete', dest }
  } catch (err) {
    state.delete(key)
    if (String(err.message).includes('cancelled')) {
      broadcastProgress(key, 'cancelled', 0)
      return { cancelled: true }
    }
    broadcastProgress(key, 'failed', 0)
    return { error: err.message }
  }
}

function deleteDownload(key) {
  const cur = state.get(key)
  if (!cur) return { ok: true }
  if (cur.abort) { try { cur.abort.abort() } catch {} }
  if (cur.dest) { try { fs.unlinkSync(cur.dest) } catch {} }
  state.delete(key)
  return { ok: true }
}

function register() {
  scanDownloadsFolder()

  // The renderer is responsible for resolving a stable file URL from the
  // server (e.g. /api/episodes/:id/file or a session-bound URL from
  // /api/playback/start). We just stream that URL to disk.
  ipcMain.handle('downloads:episode', async (_e, payload = {}) => {
    const { episodeId, url, label, originalName } = payload
    const key = keyFor({ episodeId })
    if (!key) return { error: 'No episodeId' }
    return startDownload(key, 'episode', { url, label: label || episodeId, originalName })
  })

  ipcMain.handle('downloads:movie', async (_e, payload = {}) => {
    const { movieSlug, url, label, originalName } = payload
    const key = keyFor({ movieSlug })
    if (!key) return { error: 'No movieSlug' }
    return startDownload(key, 'movie', { url, label: label || movieSlug, originalName })
  })

  ipcMain.handle('downloads:cancel', (_e, payload = {}) => {
    const { episodeId, movieSlug } = payload
    const key = keyFor({ episodeId, movieSlug })
    if (!key) return { ok: true }
    const cur = state.get(key)
    if (cur?.abort) cur.abort.abort()
    return { ok: true }
  })

  ipcMain.handle('downloads:deleteEpisode', (_e, payload = {}) => {
    const key = keyFor({ episodeId: payload.episodeId })
    return key ? deleteDownload(key) : { ok: true }
  })

  ipcMain.handle('downloads:deleteMovie', (_e, payload = {}) => {
    const key = keyFor({ movieSlug: payload.movieSlug })
    return key ? deleteDownload(key) : { ok: true }
  })

  ipcMain.handle('downloads:status', (_e, payload = {}) => {
    const key = keyFor(payload || {})
    if (!key) return null
    const cur = state.get(key)
    if (!cur) return null
    if (cur.status === 'complete' && cur.dest && !fs.existsSync(cur.dest)) {
      state.delete(key)
      return null
    }
    return { status: cur.status, progress: cur.progress, dest: cur.dest }
  })

  ipcMain.handle('downloads:list', () => {
    const out = []
    for (const [key, value] of state.entries()) {
      out.push({ key, status: value.status, progress: value.progress, dest: value.dest })
    }
    return out
  })
}

module.exports = { register }
