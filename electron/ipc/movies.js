// IPC handlers for movie operations

const { ipcMain } = require('electron')
const db = require('../db')
const movieMetadata = require('../services/movie-metadata')
const vlcPlayer = require('../services/vlc-player')

function register() {
  ipcMain.handle('movies:list', () => {
    return db.movies.all()
  })

  ipcMain.handle('movies:get', (_e, slug) => {
    return db.movies.findBySlug(slug)
  })

  ipcMain.handle('movies:add', async (_e, filePaths) => {
    const results = []
    for (const fp of filePaths) {
      const title = movieMetadata.nameFromFilename(fp)
      const year = movieMetadata.yearFromFilename(fp)
      const movie = db.movies.create({ title, file_path: fp, year })
      if (movie) {
        await movieMetadata.fetchForMovie(movie.id)
        results.push(db.movies.findById(movie.id))
      }
    }
    return results
  })

  ipcMain.handle('movies:play', async (_e, slug) => {
    const movie = db.movies.findBySlug(slug)
    if (!movie) return { error: 'Movie not found' }

    db.movies.markWatched(movie.id)

    const startTime = movie.progress_seconds > 0 &&
      movie.duration_seconds > 0 &&
      (movie.progress_seconds / movie.duration_seconds) < 0.9
      ? movie.progress_seconds : 0

    await vlcPlayer.play(movie.file_path, startTime)
    return { movie_id: movie.id }
  })

  ipcMain.handle('movies:toggle', (_e, slug) => {
    const movie = db.movies.findBySlug(slug)
    if (!movie) return null
    if (movie.watched) {
      db.movies.markUnwatched(movie.id)
    } else {
      db.movies.markWatched(movie.id)
    }
    return db.movies.findBySlug(slug)
  })

  ipcMain.handle('movies:refreshMetadata', async (_e, slug) => {
    const movie = db.movies.findBySlug(slug)
    if (!movie) return false
    return movieMetadata.fetchForMovie(movie.id)
  })

  ipcMain.handle('movies:destroy', (_e, slug) => {
    const movie = db.movies.findBySlug(slug)
    if (!movie) return false
    db.movies.destroy(movie.id)
    return true
  })
}

module.exports = { register }
