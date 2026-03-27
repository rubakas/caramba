// IPC handlers for episode operations

const { ipcMain } = require('electron')
const db = require('../db')

function register() {
  ipcMain.handle('episodes:play', async (_e, episodeId) => {
    const episode = db.episodes.findById(episodeId)
    if (!episode) return { error: 'Episode not found' }

    // Mark all prior episodes as watched
    db.episodes.markPriorWatched(episode.series_id, episode.season_number, episode.episode_number)

    // Mark current episode as watched
    db.episodes.markWatched(episodeId)

    // Create watch history entry
    const wh = db.watchHistories.create({ episode_id: episodeId })

    // Calculate resume position
    const startTime = episode.progress_seconds > 0 &&
      episode.duration_seconds > 0 &&
      (episode.progress_seconds / episode.duration_seconds) < 0.9
      ? episode.progress_seconds : 0

    // Return the info the renderer needs to start the stream
    return {
      episode_id: episodeId,
      series_id: episode.series_id,
      watch_history_id: wh.id,
      file_path: episode.file_path,
      start_time: startTime,
    }
  })

  // Get the immediate next episode after this one (for auto-play)
  ipcMain.handle('episodes:getNext', (_e, episodeId) => {
    const next = db.episodes.getNext(episodeId)
    if (!next) return null
    // Return the series info too so the frontend can build the title
    const s = db.series.findById(next.series_id)
    return {
      episode: next,
      seriesName: s?.name || '',
    }
  })

  ipcMain.handle('episodes:toggle', (_e, episodeId) => {
    const episode = db.episodes.findById(episodeId)
    if (!episode) return null
    if (episode.watched) {
      db.episodes.markUnwatched(episodeId)
    } else {
      db.episodes.markWatched(episodeId)
    }
    return db.episodes.findById(episodeId)
  })
}

module.exports = { register }
