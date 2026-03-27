// IPC handler for VLC playback status polling.
// The renderer polls this every 3s and we update DB progress.

const { ipcMain } = require('electron')
const db = require('../db')
const vlcPlayer = require('../services/vlc-player')

// Tracked playback state (replaces Rails session)
let currentEpisodeId = null
let currentMovieId = null
let currentWatchHistoryId = null

function setCurrentEpisode(episodeId, watchHistoryId) {
  currentEpisodeId = episodeId
  currentMovieId = null
  currentWatchHistoryId = watchHistoryId
}

function setCurrentMovie(movieId) {
  currentMovieId = movieId
  currentEpisodeId = null
  currentWatchHistoryId = null
}

function register() {
  ipcMain.handle('playback:status', async () => {
    const vlcStatus = await vlcPlayer.status()

    if (!vlcStatus) {
      // VLC not running — clear state
      const wasPlaying = currentEpisodeId || currentMovieId
      currentEpisodeId = null
      currentMovieId = null
      currentWatchHistoryId = null
      return { playing: false, wasPlaying: !!wasPlaying }
    }

    const isPlaying = vlcStatus.state === 'playing' || vlcStatus.state === 'paused'

    if (!isPlaying) {
      return { playing: false, state: vlcStatus.state }
    }

    const time = vlcStatus.time
    const length = vlcStatus.length

    // Update episode progress
    if (currentEpisodeId && length > 0) {
      db.episodes.updateProgress(currentEpisodeId, time, length)
      if (currentWatchHistoryId) {
        db.watchHistories.updateProgress(currentWatchHistoryId, time, length)
      }
      // Auto-mark as watched at 90%
      if (time / length >= 0.9) {
        db.episodes.markWatched(currentEpisodeId)
      }

      const ep = db.episodes.findById(currentEpisodeId)
      const s = ep ? db.series.findById(ep.series_id) : null
      return {
        playing: true,
        state: vlcStatus.state,
        time,
        length,
        position: vlcStatus.position,
        type: 'episode',
        episode_id: currentEpisodeId,
        episode_title: ep?.title,
        episode_code: ep?.code,
        series_name: s?.name,
        series_slug: s?.slug,
      }
    }

    // Update movie progress
    if (currentMovieId && length > 0) {
      db.movies.updateProgress(currentMovieId, time, length)
      if (time / length >= 0.9) {
        db.movies.markWatched(currentMovieId)
      }

      const movie = db.movies.findById(currentMovieId)
      return {
        playing: true,
        state: vlcStatus.state,
        time,
        length,
        position: vlcStatus.position,
        type: 'movie',
        movie_id: currentMovieId,
        movie_title: movie?.title,
        movie_slug: movie?.slug,
      }
    }

    return {
      playing: true,
      state: vlcStatus.state,
      time,
      length,
      position: vlcStatus.position,
    }
  })

  // Called after episodes:play or movies:play to track what's playing
  ipcMain.handle('playback:setEpisode', (_e, episodeId, watchHistoryId) => {
    setCurrentEpisode(episodeId, watchHistoryId)
    return true
  })

  ipcMain.handle('playback:setMovie', (_e, movieId) => {
    setCurrentMovie(movieId)
    return true
  })
}

module.exports = { register, setCurrentEpisode, setCurrentMovie }
