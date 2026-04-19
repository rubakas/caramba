// IPC handlers for offline downloads (media file caching)
//
// Copies media files from external sources (NAS, external drives) into the
// app's local storage so they remain playable when the source is disconnected.
// Also supports downloading from the Rails API server when local file is not available.

const { ipcMain, BrowserWindow } = require('electron')
const fs = require('fs')
const path = require('path')
const https = require('https')
const http = require('http')
const db = require('../db')
const apiConfig = require('../services/api-config')

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
 * Download a file from the Rails API server via HTTP.
 * @param {string} url - Full URL to the media endpoint (e.g., http://server/api/media/episodes/123)
 * @param {string} dest - Local destination path
 * @param {number} downloadId - ID for tracking/cancellation
 * @param {function} onProgress - Progress callback (0-1)
 * @returns {Promise<number>} - File size in bytes
 */
function downloadFromServer(url, dest, downloadId, onProgress) {
  return new Promise((resolve, reject) => {
    const ac = new AbortController()
    activeCopies.set(downloadId, ac)

    const parsedUrl = new URL(url)
    const httpModule = parsedUrl.protocol === 'https:' ? https : http

    const request = httpModule.get(url, (res) => {
      if (res.statusCode === 302 || res.statusCode === 301) {
        // Follow redirect
        activeCopies.delete(downloadId)
        return downloadFromServer(res.headers.location, dest, downloadId, onProgress)
          .then(resolve)
          .catch(reject)
      }

      if (res.statusCode !== 200) {
        activeCopies.delete(downloadId)
        return reject(new Error(`Server returned ${res.statusCode}: ${res.statusMessage}`))
      }

      const totalSize = parseInt(res.headers['content-length'], 10) || 0
      const writeStream = fs.createWriteStream(dest)

      let downloaded = 0
      let lastReportedPct = -1

      ac.signal.addEventListener('abort', () => {
        request.destroy()
        res.destroy()
        writeStream.destroy()
        try { fs.unlinkSync(dest) } catch {}
      })

      res.on('data', (chunk) => {
        downloaded += chunk.length
        if (totalSize > 0) {
          const pct = downloaded / totalSize
          const roundedPct = Math.floor(pct * 100)
          if (roundedPct > lastReportedPct) {
            lastReportedPct = roundedPct
            onProgress(pct)
          }
        }
      })

      res.on('error', (err) => {
        writeStream.destroy()
        activeCopies.delete(downloadId)
        try { fs.unlinkSync(dest) } catch {}
        reject(err)
      })

      writeStream.on('error', (err) => {
        res.destroy()
        activeCopies.delete(downloadId)
        try { fs.unlinkSync(dest) } catch {}
        reject(err)
      })

      writeStream.on('finish', () => {
        activeCopies.delete(downloadId)
        if (ac.signal.aborted) {
          reject(new Error('Download cancelled'))
        } else {
          resolve(downloaded)
        }
      })

      res.pipe(writeStream)
    })

    request.on('error', (err) => {
      activeCopies.delete(downloadId)
      try { fs.unlinkSync(dest) } catch {}
      reject(err)
    })
  })
}

/**
 * Get the server URL for media downloads, or null if API mode is not enabled.
 */
function getServerMediaUrl(type, id) {
  if (!apiConfig.isEnabled()) return null
  const serverUrl = apiConfig.getServerUrl()
  if (!serverUrl) return null
  // Remove trailing slash and build media URL
  const base = serverUrl.replace(/\/+$/, '')
  return `${base}/api/media/${type}/${id}`
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
  // Accepts either { episodeId } or { episodeId, filePath, serverEpisodeId } for hybrid mode compatibility
  ipcMain.handle('downloads:episode', async (_e, arg) => {
    // Support both old format (just episodeId) and new format ({ episodeId, filePath, serverEpisodeId })
    const episodeId = typeof arg === 'object' ? arg.episodeId : arg
    const filePath = typeof arg === 'object' ? arg.filePath : null
    const serverEpisodeId = typeof arg === 'object' ? arg.serverEpisodeId : null

    // Try to find episode by ID first, then fall back to file_path lookup
    let episode = db.episodes.findById(episodeId)
    if (!episode && filePath) {
      episode = db.episodes.findByFilePath(filePath)
    }
    if (!episode) return { error: 'Episode not found in local database' }
    if (!episode.file_path) return { error: 'Episode has no file path' }

    // Use the local episode ID for download tracking
    const localEpisodeId = episode.id

    // Check if already downloaded
    const existing = db.downloads.forEpisode(localEpisodeId)
    if (existing && existing.status === 'complete' && fs.existsSync(existing.file_path)) {
      return { error: 'Episode is already downloaded' }
    }
    // Clean up any stale/failed download record
    if (existing) db.downloads.destroy(existing.id)

    const dest = buildDestPath('episode', localEpisodeId, episode.file_path)
    const dl = db.safeWrite(() =>
      db.downloads.create({ episode_id: localEpisodeId, file_path: dest, status: 'downloading' })
    )

    // Determine download source: local file or server API
    const localFileExists = fs.existsSync(episode.file_path)
    const serverUrl = !localFileExists ? getServerMediaUrl('episodes', serverEpisodeId || episodeId) : null

    if (!localFileExists && !serverUrl) {
      db.downloads.updateStatus(dl.id, 'failed', 0)
      sendProgress(dl.id, localEpisodeId, null, 'failed', 0)
      return { error: 'Source file not found locally and server API is not configured' }
    }

    try {
      let fileSize
      if (localFileExists) {
        // Download from local filesystem
        fileSize = await copyFileWithProgress(episode.file_path, dest, dl.id, (pct) => {
          db.downloads.updateStatus(dl.id, 'downloading', pct)
          sendProgress(dl.id, localEpisodeId, null, 'downloading', pct)
        })
      } else {
        // Download from server API
        fileSize = await downloadFromServer(serverUrl, dest, dl.id, (pct) => {
          db.downloads.updateStatus(dl.id, 'downloading', pct)
          sendProgress(dl.id, localEpisodeId, null, 'downloading', pct)
        })
      }
      db.downloads.updateStatus(dl.id, 'complete', 1)
      db.downloads.updateFileSize(dl.id, fileSize)
      sendProgress(dl.id, localEpisodeId, null, 'complete', 1)
      return { ok: true, download: db.downloads.findById(dl.id) }
    } catch (err) {
      if (err.message === 'Download cancelled') {
        db.downloads.destroy(dl.id)
        return { cancelled: true }
      }
      db.downloads.updateStatus(dl.id, 'failed', 0)
      sendProgress(dl.id, localEpisodeId, null, 'failed', 0)
      return { error: err.message }
    }
  })

  // Download all episodes in a season
  // Accepts either (showId, seasonNumber) or ({ showId, showSlug, seasonNumber }) for hybrid mode
  ipcMain.handle('downloads:season', async (_e, arg1, arg2) => {
    let showId, seasonNumber

    if (typeof arg1 === 'object') {
      // New format: { showId, showSlug, seasonNumber }
      showId = arg1.showId
      seasonNumber = arg1.seasonNumber
      // Try to find local show by ID first, then by slug
      let localShow = db.shows.findById(showId)
      if (!localShow && arg1.showSlug) {
        localShow = db.shows.findBySlug(arg1.showSlug)
      }
      if (!localShow) return { error: 'Show not found locally' }
      showId = localShow.id
    } else {
      // Old format: (showId, seasonNumber)
      showId = arg1
      seasonNumber = arg2
    }

    const seasonEps = db.episodes.forSeason(showId, seasonNumber)
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
  // Accepts either movieId or { movieId, filePath, serverMovieId } for hybrid mode
  ipcMain.handle('downloads:movie', async (_e, arg) => {
    const movieId = typeof arg === 'object' ? arg.movieId : arg
    const filePath = typeof arg === 'object' ? arg.filePath : null
    const serverMovieId = typeof arg === 'object' ? arg.serverMovieId : null

    // Try to find movie by ID first, then fall back to file_path lookup
    let movie = db.movies.findById(movieId)
    if (!movie && filePath) {
      movie = db.movies.findByFilePath(filePath)
    }
    if (!movie) return { error: 'Movie not found in local database' }
    if (!movie.file_path) return { error: 'Movie has no file path' }

    const localMovieId = movie.id

    const existing = db.downloads.forMovie(localMovieId)
    if (existing && existing.status === 'complete' && fs.existsSync(existing.file_path)) {
      return { error: 'Movie is already downloaded' }
    }
    if (existing) db.downloads.destroy(existing.id)

    const dest = buildDestPath('movie', localMovieId, movie.file_path)
    const dl = db.safeWrite(() =>
      db.downloads.create({ movie_id: localMovieId, file_path: dest, status: 'downloading' })
    )

    // Determine download source: local file or server API
    const localFileExists = fs.existsSync(movie.file_path)
    const serverUrl = !localFileExists ? getServerMediaUrl('movies', serverMovieId || movieId) : null

    if (!localFileExists && !serverUrl) {
      db.downloads.updateStatus(dl.id, 'failed', 0)
      sendProgress(dl.id, null, localMovieId, 'failed', 0)
      return { error: 'Source file not found locally and server API is not configured' }
    }

    try {
      let fileSize
      if (localFileExists) {
        fileSize = await copyFileWithProgress(movie.file_path, dest, dl.id, (pct) => {
          db.downloads.updateStatus(dl.id, 'downloading', pct)
          sendProgress(dl.id, null, localMovieId, 'downloading', pct)
        })
      } else {
        fileSize = await downloadFromServer(serverUrl, dest, dl.id, (pct) => {
          db.downloads.updateStatus(dl.id, 'downloading', pct)
          sendProgress(dl.id, null, localMovieId, 'downloading', pct)
        })
      }
      db.downloads.updateStatus(dl.id, 'complete', 1)
      db.downloads.updateFileSize(dl.id, fileSize)
      sendProgress(dl.id, null, localMovieId, 'complete', 1)
      return { ok: true, download: db.downloads.findById(dl.id) }
    } catch (err) {
      if (err.message === 'Download cancelled') {
        db.downloads.destroy(dl.id)
        return { cancelled: true }
      }
      db.downloads.updateStatus(dl.id, 'failed', 0)
      sendProgress(dl.id, null, localMovieId, 'failed', 0)
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
  // Accepts either episodeId or { episodeId, filePath } for hybrid mode compatibility
  ipcMain.handle('downloads:deleteEpisode', (_e, arg) => {
    const episodeId = typeof arg === 'object' ? arg.episodeId : arg
    const filePath = typeof arg === 'object' ? arg.filePath : null

    // Try to find episode by ID first, then fall back to file_path lookup
    let localEpisodeId = episodeId
    const episode = db.episodes.findById(episodeId)
    if (!episode && filePath) {
      const localEp = db.episodes.findByFilePath(filePath)
      if (localEp) localEpisodeId = localEp.id
    }

    const dl = db.downloads.forEpisode(localEpisodeId)
    if (!dl) return { ok: true }
    // Cancel if in progress
    const ac = activeCopies.get(dl.id)
    if (ac) ac.abort()
    try { fs.unlinkSync(dl.file_path) } catch {}
    db.downloads.destroy(dl.id)
    return { ok: true }
  })

  // Delete all downloaded episodes for a season
  // Accepts either (showId, seasonNumber) or ({ showId, showSlug, seasonNumber }) for hybrid mode
  ipcMain.handle('downloads:deleteSeason', (_e, arg1, arg2) => {
    let showId, seasonNumber

    if (typeof arg1 === 'object') {
      showId = arg1.showId
      seasonNumber = arg1.seasonNumber
      // Try to find local show by ID first, then by slug
      let localShow = db.shows.findById(showId)
      if (!localShow && arg1.showSlug) {
        localShow = db.shows.findBySlug(arg1.showSlug)
      }
      if (!localShow) return { ok: true, deleted: 0 }
      showId = localShow.id
    } else {
      showId = arg1
      seasonNumber = arg2
    }

    const seasonDls = db.downloads.forSeason(showId, seasonNumber)
    for (const dl of seasonDls) {
      const ac = activeCopies.get(dl.id)
      if (ac) ac.abort()
      try { fs.unlinkSync(dl.file_path) } catch {}
      db.downloads.destroy(dl.id)
    }
    return { ok: true, deleted: seasonDls.length }
  })

  // Delete a downloaded movie file
  // Accepts either movieId or { movieId, filePath } for hybrid mode
  ipcMain.handle('downloads:deleteMovie', (_e, arg) => {
    const movieId = typeof arg === 'object' ? arg.movieId : arg
    const filePath = typeof arg === 'object' ? arg.filePath : null

    // Try to find movie by ID first, then fall back to file_path lookup
    let localMovieId = movieId
    const movie = db.movies.findById(movieId)
    if (!movie && filePath) {
      const localMovie = db.movies.findByFilePath(filePath)
      if (localMovie) localMovieId = localMovie.id
    }

    const dl = db.downloads.forMovie(localMovieId)
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

  // Get download status for episodes by file paths
  // Used by hybrid adapter to enrich server data with local download status
  ipcMain.handle('downloads:statusByFilePaths', (_e, filePaths) => {
    if (!Array.isArray(filePaths) || filePaths.length === 0) return {}

    const result = {}
    for (const filePath of filePaths) {
      if (!filePath) continue
      // Find local episode by file path
      const episode = db.episodes.findByFilePath(filePath)
      if (episode) {
        const dl = db.downloads.forEpisode(episode.id)
        if (dl) {
          result[filePath] = dl
        }
      }
    }
    return result
  })

  // Get download status for a movie by file path
  ipcMain.handle('downloads:movieStatusByFilePath', (_e, filePath) => {
    if (!filePath) return null
    const movie = db.movies.findByFilePath(filePath)
    if (movie) {
      return db.downloads.forMovie(movie.id)
    }
    return null
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
