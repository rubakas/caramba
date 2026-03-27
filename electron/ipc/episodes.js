// IPC handlers for episode operations

const { ipcMain } = require('electron')
const db = require('../db')
const vlcPlayer = require('../services/vlc-player')

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

    // Launch VLC
    await vlcPlayer.play(episode.file_path, startTime)

    return { episode_id: episodeId, watch_history_id: wh.id }
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
