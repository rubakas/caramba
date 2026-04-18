// IPC handlers for series operations

const { ipcMain } = require('electron')
const fs = require('fs')
const db = require('../db')
const mediaScanner = require('../services/media-scanner')
const metadataFetcher = require('../services/metadata-fetcher')

const VLC_APP_PATH = '/Applications/VLC.app'

function register() {
  ipcMain.handle('series:list', () => {
    return db.series.all().map(s => {
      const { mode } = db.episodes.continueFor(s.id)
      return { ...s, has_continue: mode === 'resume' || mode === 'next' }
    })
  })

  ipcMain.handle('series:get', (_e, slug) => {
    const s = db.series.findBySlug(slug)
    if (!s) return null
    return {
      ...s,
      season_count: db.series.seasonCount(s.id),
      total_watch_time: db.series.totalWatchTime(s.id),
      total_episodes: db.episodes.countForSeries(s.id),
      watched_episodes: db.episodes.countWatchedForSeries(s.id),
    }
  })

  // Combined handler: returns everything SeriesShow needs in one IPC round-trip.
  ipcMain.handle('series:show', (_e, slug) => {
    const s = db.series.findBySlug(slug)
    if (!s) return null
    const episodes = db.episodes.forSeries(s.id)
    const seasons = db.episodes.seasons(s.id)
    const totalWatchTime = db.series.totalWatchTime(s.id)
    const continueCta = db.episodes.continueFor(s.id)
    const vlcAvailable = process.platform === 'darwin' ? fs.existsSync(VLC_APP_PATH) : false

    // Attach download status to each episode
    const seriesDownloads = db.downloads.forSeries(s.id)
    const dlByEpisode = new Map(seriesDownloads.map(d => [d.episode_id, d]))
    const episodesWithDl = episodes.map(ep => ({
      ...ep,
      download: dlByEpisode.get(ep.id) || null,
    }))

    return {
      series: {
        ...s,
        season_count: seasons.length,
        total_watch_time: totalWatchTime,
        total_episodes: episodes.length,
        watched_episodes: episodes.filter(e => e.watched).length,
      },
      episodes: episodesWithDl,
      seasons,
      continue: continueCta,
      vlcAvailable,
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

  ipcMain.handle('series:getContinue', (_e, slug) => {
    const s = db.series.findBySlug(slug)
    if (!s) return { mode: 'empty', episode: null }
    return db.episodes.continueFor(s.id)
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
    // Clean up downloaded files before destroying (CASCADE will delete DB records)
    const seriesDownloads = db.downloads.forSeries(s.id)
    for (const dl of seriesDownloads) {
      try { fs.unlinkSync(dl.file_path) } catch {}
    }
    db.series.destroy(s.id)
    return true
  })

  ipcMain.handle('series:relocate', (_e, slug, newMediaPath) => {
    const s = db.series.findBySlug(slug)
    if (!s) return { error: 'Series not found' }
    if (!newMediaPath) return { error: 'No folder path provided' }
    if (!fs.existsSync(newMediaPath)) return { error: 'Folder does not exist: ' + newMediaPath }
    try {
      const updated = db.series.relocate(s.id, newMediaPath)
      // Re-scan to pick up any new files and update paths for renamed files
      mediaScanner.scan(s.id)
      return { ok: true, series: updated }
    } catch (err) {
      return { error: err.message }
    }
  })
}

module.exports = { register }
