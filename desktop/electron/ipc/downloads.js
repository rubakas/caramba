// IPC handlers for offline downloads (media file caching)
//
// Copies media files from external sources (NAS, external drives) into the
// app's local storage so they remain playable when the source is disconnected.

const { ipcMain, BrowserWindow } = require('electron')
const fs = require('fs')
const path = require('path')
const db = require('../db')

// Track active copy operations so they can be cancelled
const activeCopies = new Map() // downloadId -> AbortController

/**
 * Build the local destination path for a downloaded file.
 * episodes/<episodeId>_<originalFilename>
 * movies/<movieId>_<originalFilename>
 */
function buildDestPath(type, id, originalPath) {
  const dir = path.join(db.getDownloadsPath(), type === 'episode' ? 'episodes' : 'movies')
  fs.mkdirSync(dir, { recursive: true })
  const ext = path.extname(originalPath)
  const baseName = path.basename(originalPath, ext)
  // Sanitize the base name to avoid filesystem issues
  const safe = baseName.replace(/[^a-zA-Z0-9._-]/g, '_').substring(0, 100)
  return path.join(dir, `${id}_${safe}${ext}`)
}

/**
 * Copy a file with progress reporting via streams.
 * Returns a promise that resolves when copy is complete.
 */
function copyFileWithProgress(src, dest, downloadId, onProgress) {
  return new Promise((resolve, reject) => {
    const ac = new AbortController()
    activeCopies.set(downloadId, ac)

    let srcSize = 0
    try {
      srcSize = fs.statSync(src).size
    } catch (err) {
      activeCopies.delete(downloadId)
      return reject(new Error('Source file not found: ' + src))
    }

    const readStream = fs.createReadStream(src)
    const writeStream = fs.createWriteStream(dest)

    let copied = 0
    let lastReportedPct = -1

    ac.signal.addEventListener('abort', () => {
      readStream.destroy()
      writeStream.destroy()
      // Clean up partial file
      try { fs.unlinkSync(dest) } catch {}
    })

    readStream.on('data', (chunk) => {
      copied += chunk.length
      const pct = srcSize > 0 ? copied / srcSize : 0
      // Report progress at most every 1% to avoid flooding IPC
      const roundedPct = Math.floor(pct * 100)
      if (roundedPct > lastReportedPct) {
        lastReportedPct = roundedPct
        onProgress(pct)
      }
    })

    readStream.on('error', (err) => {
      writeStream.destroy()
      activeCopies.delete(downloadId)
      try { fs.unlinkSync(dest) } catch {}
      reject(err)
    })

    writeStream.on('error', (err) => {
      readStream.destroy()
      activeCopies.delete(downloadId)
      try { fs.unlinkSync(dest) } catch {}
      reject(err)
    })

    writeStream.on('finish', () => {
      activeCopies.delete(downloadId)
      if (ac.signal.aborted) {
        reject(new Error('Download cancelled'))
      } else {
        resolve(srcSize)
      }
    })

    readStream.pipe(writeStream)
  })
}

/**
 * Send download progress to the renderer process.
 */
function sendProgress(downloadId, episodeId, movieId, status, progress) {
  try {
    const win = BrowserWindow.getAllWindows()[0]
    if (win) {
      win.webContents.send('downloads:progress', { downloadId, episodeId, movieId, status, progress })
    }
  } catch {}
}

/**
 * Resolve the effective file path for playback: downloaded copy > original.
 * Returns the path to use, or null if neither exists.
 */
function resolvePlaybackPath(originalPath, episodeId, movieId) {
  // Check for a completed download
  const dl = episodeId ? db.downloads.forEpisode(episodeId) : movieId ? db.downloads.forMovie(movieId) : null

  if (dl && dl.status === 'complete') {
    if (fs.existsSync(dl.file_path)) {
      return dl.file_path
    }
    // Downloaded file is missing on disk — clean up stale record
    db.downloads.destroy(dl.id)
  }

  // Fall back to original
  if (originalPath && fs.existsSync(originalPath)) {
    return originalPath
  }

  return null
}

function register() {
  // Download a single episode
  ipcMain.handle('downloads:episode', async (_e, episodeId) => {
    const episode = db.episodes.findById(episodeId)
    if (!episode) return { error: 'Episode not found' }
    if (!episode.file_path) return { error: 'Episode has no file path' }
    if (!fs.existsSync(episode.file_path)) return { error: 'Source file not found: ' + episode.file_path }

    // Check if already downloaded
    const existing = db.downloads.forEpisode(episodeId)
    if (existing && existing.status === 'complete' && fs.existsSync(existing.file_path)) {
      return { error: 'Episode is already downloaded' }
    }
    // Clean up any stale/failed download record
    if (existing) db.downloads.destroy(existing.id)

    const dest = buildDestPath('episode', episodeId, episode.file_path)
    const dl = db.safeWrite(() =>
      db.downloads.create({ episode_id: episodeId, file_path: dest, status: 'downloading' })
    )

    try {
      const fileSize = await copyFileWithProgress(episode.file_path, dest, dl.id, (pct) => {
        db.downloads.updateStatus(dl.id, 'downloading', pct)
        sendProgress(dl.id, episodeId, null, 'downloading', pct)
      })
      db.downloads.updateStatus(dl.id, 'complete', 1)
      db.downloads.updateFileSize(dl.id, fileSize)
      sendProgress(dl.id, episodeId, null, 'complete', 1)
      return { ok: true, download: db.downloads.findById(dl.id) }
    } catch (err) {
      if (err.message === 'Download cancelled') {
        db.downloads.destroy(dl.id)
        return { cancelled: true }
      }
      db.downloads.updateStatus(dl.id, 'failed', 0)
      sendProgress(dl.id, episodeId, null, 'failed', 0)
      return { error: err.message }
    }
  })

  // Download all episodes in a season
  ipcMain.handle('downloads:season', async (_e, seriesId, seasonNumber) => {
    const seasonEps = db.episodes.forSeason(seriesId, seasonNumber)
    if (seasonEps.length === 0) return { error: 'No episodes found for this season' }

    const results = []
    for (const episode of seasonEps) {
      if (!episode.file_path || !fs.existsSync(episode.file_path)) {
        results.push({ episodeId: episode.id, skipped: true, reason: 'File not found' })
        continue
      }

      const existing = db.downloads.forEpisode(episode.id)
      if (existing && existing.status === 'complete' && fs.existsSync(existing.file_path)) {
        results.push({ episodeId: episode.id, skipped: true, reason: 'Already downloaded' })
        continue
      }
      if (existing) db.downloads.destroy(existing.id)

      const dest = buildDestPath('episode', episode.id, episode.file_path)
      const dl = db.safeWrite(() =>
        db.downloads.create({ episode_id: episode.id, file_path: dest, status: 'downloading' })
      )

      try {
        const fileSize = await copyFileWithProgress(episode.file_path, dest, dl.id, (pct) => {
          db.downloads.updateStatus(dl.id, 'downloading', pct)
          sendProgress(dl.id, episode.id, null, 'downloading', pct)
        })
        db.downloads.updateStatus(dl.id, 'complete', 1)
        db.downloads.updateFileSize(dl.id, fileSize)
        sendProgress(dl.id, episode.id, null, 'complete', 1)
        results.push({ episodeId: episode.id, ok: true })
      } catch (err) {
        if (err.message === 'Download cancelled') {
          db.downloads.destroy(dl.id)
          results.push({ episodeId: episode.id, cancelled: true })
          break // Stop the whole season download on cancel
        }
        db.downloads.updateStatus(dl.id, 'failed', 0)
        sendProgress(dl.id, episode.id, null, 'failed', 0)
        results.push({ episodeId: episode.id, error: err.message })
      }
    }

    return { results }
  })

  // Download a single movie
  ipcMain.handle('downloads:movie', async (_e, movieId) => {
    const movie = db.movies.findById(movieId)
    if (!movie) return { error: 'Movie not found' }
    if (!movie.file_path) return { error: 'Movie has no file path' }
    if (!fs.existsSync(movie.file_path)) return { error: 'Source file not found: ' + movie.file_path }

    const existing = db.downloads.forMovie(movieId)
    if (existing && existing.status === 'complete' && fs.existsSync(existing.file_path)) {
      return { error: 'Movie is already downloaded' }
    }
    if (existing) db.downloads.destroy(existing.id)

    const dest = buildDestPath('movie', movieId, movie.file_path)
    const dl = db.safeWrite(() =>
      db.downloads.create({ movie_id: movieId, file_path: dest, status: 'downloading' })
    )

    try {
      const fileSize = await copyFileWithProgress(movie.file_path, dest, dl.id, (pct) => {
        db.downloads.updateStatus(dl.id, 'downloading', pct)
        sendProgress(dl.id, null, movieId, 'downloading', pct)
      })
      db.downloads.updateStatus(dl.id, 'complete', 1)
      db.downloads.updateFileSize(dl.id, fileSize)
      sendProgress(dl.id, null, movieId, 'complete', 1)
      return { ok: true, download: db.downloads.findById(dl.id) }
    } catch (err) {
      if (err.message === 'Download cancelled') {
        db.downloads.destroy(dl.id)
        return { cancelled: true }
      }
      db.downloads.updateStatus(dl.id, 'failed', 0)
      sendProgress(dl.id, null, movieId, 'failed', 0)
      return { error: err.message }
    }
  })

  // Cancel an in-progress download
  ipcMain.handle('downloads:cancel', (_e, downloadId) => {
    const ac = activeCopies.get(downloadId)
    if (ac) {
      ac.abort()
      return { ok: true }
    }
    // If not actively copying, just clean up the record
    const dl = db.downloads.findById(downloadId)
    if (dl) {
      try { fs.unlinkSync(dl.file_path) } catch {}
      db.downloads.destroy(dl.id)
    }
    return { ok: true }
  })

  // Delete a downloaded episode file
  ipcMain.handle('downloads:deleteEpisode', (_e, episodeId) => {
    const dl = db.downloads.forEpisode(episodeId)
    if (!dl) return { ok: true }
    // Cancel if in progress
    const ac = activeCopies.get(dl.id)
    if (ac) ac.abort()
    try { fs.unlinkSync(dl.file_path) } catch {}
    db.downloads.destroy(dl.id)
    return { ok: true }
  })

  // Delete all downloaded episodes for a season
  ipcMain.handle('downloads:deleteSeason', (_e, seriesId, seasonNumber) => {
    const seasonDls = db.downloads.forSeason(seriesId, seasonNumber)
    for (const dl of seasonDls) {
      const ac = activeCopies.get(dl.id)
      if (ac) ac.abort()
      try { fs.unlinkSync(dl.file_path) } catch {}
      db.downloads.destroy(dl.id)
    }
    return { ok: true, deleted: seasonDls.length }
  })

  // Delete a downloaded movie file
  ipcMain.handle('downloads:deleteMovie', (_e, movieId) => {
    const dl = db.downloads.forMovie(movieId)
    if (!dl) return { ok: true }
    const ac = activeCopies.get(dl.id)
    if (ac) ac.abort()
    try { fs.unlinkSync(dl.file_path) } catch {}
    db.downloads.destroy(dl.id)
    return { ok: true }
  })

  // List all downloads
  ipcMain.handle('downloads:list', () => {
    return db.downloads.all()
  })

  // Get storage info
  ipcMain.handle('downloads:storageInfo', () => {
    return {
      totalSize: db.downloads.totalSize(),
      downloadsPath: db.getDownloadsPath(),
    }
  })
}

module.exports = { register, resolvePlaybackPath }
