// IPC handlers for series operations

const { ipcMain } = require('electron')
const db = require('../db')
const mediaScanner = require('../services/media-scanner')
const metadataFetcher = require('../services/metadata-fetcher')

function register() {
  ipcMain.handle('series:list', () => {
    return db.series.all()
  })

  ipcMain.handle('series:get', (_e, slug) => {
    const s = db.series.findBySlug(slug)
    if (!s) return null
    return {
      ...s,
      season_count: db.series.seasonCount(s.id),
      total_watch_time: db.series.totalWatchTime(s.id),
      total_episodes: db.episodes.forSeries(s.id).length,
      watched_episodes: db.episodes.forSeries(s.id).filter(e => e.watched).length,
    }
  })

  ipcMain.handle('series:getEpisodes', (_e, slug) => {
    const s = db.series.findBySlug(slug)
    if (!s) return []
    return db.episodes.forSeries(s.id)
  })

  ipcMain.handle('series:getSeasons', (_e, slug) => {
    const s = db.series.findBySlug(slug)
    if (!s) return []
    return db.episodes.seasons(s.id)
  })

  ipcMain.handle('series:getResumable', (_e, slug) => {
    const s = db.series.findBySlug(slug)
    if (!s) return null
    return db.episodes.resumable(s.id)
  })

  ipcMain.handle('series:getNextUp', (_e, slug) => {
    const s = db.series.findBySlug(slug)
    if (!s) return null
    return db.episodes.nextUp(s.id)
  })

  ipcMain.handle('series:add', async (_e, folderPath) => {
    const name = mediaScanner.nameFromPath(folderPath.trim())
    let s = db.series.findByMediaPath(folderPath.trim())
    if (!s) {
      s = db.series.create({ name, media_path: folderPath.trim() })
    }
    mediaScanner.scan(s.id)
    await metadataFetcher.fetchForSeries(s.id)
    return db.series.findById(s.id)
  })

  ipcMain.handle('series:scan', (_e, slug) => {
    const s = db.series.findBySlug(slug)
    if (!s) return 0
    return mediaScanner.scan(s.id)
  })

  ipcMain.handle('series:refreshMetadata', async (_e, slug) => {
    const s = db.series.findBySlug(slug)
    if (!s) return false
    return metadataFetcher.fetchForSeries(s.id)
  })

  ipcMain.handle('series:destroy', (_e, slug) => {
    const s = db.series.findBySlug(slug)
    if (!s) return false
    db.series.destroy(s.id)
    return true
  })
}

module.exports = { register }
