// IPC handlers for show operations

const { ipcMain } = require('electron')
const fs = require('fs')
const db = require('../db')
const mediaScanner = require('../services/media-scanner')
const metadataFetcher = require('../services/metadata-fetcher')

const VLC_APP_PATH = '/Applications/VLC.app'

function register() {
  ipcMain.handle('shows:list', () => {
    return db.shows.all().map(s => {
      const { mode } = db.episodes.continueFor(s.id)
      return { ...s, has_continue: mode === 'resume' || mode === 'next' }
    })
  })

  ipcMain.handle('shows:get', (_e, slug) => {
    const s = db.shows.findBySlug(slug)
    if (!s) return null
    return {
      ...s,
      season_count: db.shows.seasonCount(s.id),
      total_watch_time: db.shows.totalWatchTime(s.id),
      total_episodes: db.episodes.countForShow(s.id),
      watched_episodes: db.episodes.countWatchedForShow(s.id),
    }
  })

  // Combined handler: returns everything Show needs in one IPC round-trip.
  ipcMain.handle('shows:show', (_e, slug) => {
    const s = db.shows.findBySlug(slug)
    if (!s) return null
    const episodes = db.episodes.forShow(s.id)
    const seasons = db.episodes.seasons(s.id)
    const totalWatchTime = db.shows.totalWatchTime(s.id)
    const continueCta = db.episodes.continueFor(s.id)
    const vlcAvailable = process.platform === 'darwin' ? fs.existsSync(VLC_APP_PATH) : false

    // Attach download status to each episode
    const showDownloads = db.downloads.forShow(s.id)
    const dlByEpisode = new Map(showDownloads.map(d => [d.episode_id, d]))
    const episodesWithDl = episodes.map(ep => ({
      ...ep,
      download: dlByEpisode.get(ep.id) || null,
    }))

    return {
      show: {
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

  ipcMain.handle('shows:getEpisodes', (_e, slug) => {
    const s = db.shows.findBySlug(slug)
    if (!s) return []
    return db.episodes.forShow(s.id)
  })

  ipcMain.handle('shows:getSeasons', (_e, slug) => {
    const s = db.shows.findBySlug(slug)
    if (!s) return []
    return db.episodes.seasons(s.id)
  })

  ipcMain.handle('shows:getContinue', (_e, slug) => {
    const s = db.shows.findBySlug(slug)
    if (!s) return { mode: 'empty', episode: null }
    return db.episodes.continueFor(s.id)
  })

  ipcMain.handle('shows:add', async (_e, folderPath) => {
    const name = mediaScanner.nameFromPath(folderPath.trim())
    let s = db.shows.findByMediaPath(folderPath.trim())
    if (!s) {
      s = db.shows.create({ name, media_path: folderPath.trim() })
    }
    mediaScanner.scan(s.id)
    await metadataFetcher.fetchForShow(s.id)
    return db.shows.findById(s.id)
  })

  ipcMain.handle('shows:scan', (_e, slug) => {
    const s = db.shows.findBySlug(slug)
    if (!s) return 0
    return mediaScanner.scan(s.id)
  })

  ipcMain.handle('shows:refreshMetadata', async (_e, slug) => {
    const s = db.shows.findBySlug(slug)
    if (!s) return false
    return metadataFetcher.fetchForShow(s.id)
  })

  ipcMain.handle('shows:destroy', (_e, slug) => {
    const s = db.shows.findBySlug(slug)
    if (!s) return false
    // Clean up downloaded files before destroying (CASCADE will delete DB records)
    const showDownloads = db.downloads.forShow(s.id)
    for (const dl of showDownloads) {
      try { fs.unlinkSync(dl.file_path) } catch {}
    }
    db.shows.destroy(s.id)
    return true
  })

  ipcMain.handle('shows:relocate', (_e, slug, newMediaPath) => {
    const s = db.shows.findBySlug(slug)
    if (!s) return { error: 'Show not found' }
    if (!newMediaPath) return { error: 'No folder path provided' }
    if (!fs.existsSync(newMediaPath)) return { error: 'Folder does not exist: ' + newMediaPath }
    try {
      const updated = db.shows.relocate(s.id, newMediaPath)
      // Re-scan to pick up any new files and update paths for renamed files
      mediaScanner.scan(s.id)
      return { ok: true, show: updated }
    } catch (err) {
      return { error: err.message }
    }
  })
}

module.exports = { register }
