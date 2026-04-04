// IPC handler for in-app video playback via ffmpeg transcoder.
// Replaces VLC-based polling with transcoder + HTML5 <video> approach.

const { ipcMain, shell } = require('electron')
const { spawn } = require('child_process')
const fs = require('fs')
const db = require('../db')
const transcoder = require('../services/transcoder')

const VLC_APP_PATH = '/Applications/VLC.app'
const VLC_BIN_PATH = '/Applications/VLC.app/Contents/MacOS/VLC'
const VLC_HTTP_PORT = 9090
const VLC_HTTP_PASSWORD = 'caramba'
const VLC_AUTH_HEADER = 'Basic ' + Buffer.from(`:${VLC_HTTP_PASSWORD}`).toString('base64')
const VLC_POLL_INTERVAL = 3000 // 3 seconds

// VLC external playback tracking state
let vlcPollTimer = null
let vlcEpisodeId = null
let vlcMovieId = null
let vlcWatchHistoryId = null
let vlcLastTime = 0
let vlcLastLength = 0

// Tracked playback state
let currentEpisodeId = null
let currentMovieId = null
let currentWatchHistoryId = null
let currentDuration = 0
let currentSeekBase = 0 // the -ss offset used when starting ffmpeg
let currentAudioStreamIndex = null // preferred audio stream index

function register() {
  // Start playback: probe file, start transcoder, extract subs
  ipcMain.handle('playback:start', async (_e, filePath, startTime = 0, prefs = null) => {
    try {
      if (!filePath || !fs.existsSync(filePath)) {
        return { error: 'File not found: ' + (filePath || '(no path)') }
      }

      const info = await transcoder.probe(filePath)

      // Pick audio track: saved preference (by language) > English > first
      let audioStreamIndex = null
      if (info.audioStreams.length > 0) {
        if (prefs && prefs.audioLanguage) {
          const saved = info.audioStreams.find(s => s.language === prefs.audioLanguage)
          audioStreamIndex = saved ? saved.index : info.audioStreams[0].index
        } else {
          const eng = info.audioStreams.find(s => s.language === 'eng' || s.language === 'en')
          audioStreamIndex = eng ? eng.index : info.audioStreams[0].index
        }
      }

      // Pick subtitle track: saved preference (by language / off) > first text sub
      let subtitleStreamIndex = null
      let subtitleUrl = null
      if (prefs && prefs.subtitleOff) {
        subtitleStreamIndex = null
      } else if (prefs && prefs.subtitleLanguage) {
        const saved = info.subtitleStreams.find(s => s.isText && s.language === prefs.subtitleLanguage)
        if (saved) subtitleStreamIndex = saved.index
      } else {
        const textSub = info.subtitleStreams.find(s => s.isText)
        if (textSub) subtitleStreamIndex = textSub.index
      }

      // Extract subtitles if a track was selected
      if (subtitleStreamIndex != null) {
        try {
          const vtt = await transcoder.extractSubtitles(filePath, subtitleStreamIndex)
          if (vtt) {
            const main = require('../main')
            main.setSubtitleCache(vtt)
            subtitleUrl = 'subtitle://track?t=' + Date.now()
          }
        } catch {}
      }

      // Start transcoding
      transcoder.start(filePath, startTime, { audioStreamIndex })
      currentSeekBase = startTime
      currentDuration = info.duration
      currentAudioStreamIndex = audioStreamIndex

      return {
        streamUrl: 'stream://video',
        duration: info.duration,
        startTime,
        subtitleUrl,
        video: info.video,
        audioStreams: info.audioStreams,
        subtitleStreams: info.subtitleStreams,
        activeAudioIndex: audioStreamIndex,
        activeSubtitleIndex: subtitleStreamIndex,
      }
    } catch (err) {
      console.error('playback:start error:', err)
      return { error: err.message }
    }
  })

  // Seek: restart ffmpeg at new position
  ipcMain.handle('playback:seek', async (_e, seekTime) => {
    const filePath = transcoder.getActiveFilePath()
    if (!filePath) return { error: 'No active playback' }

    transcoder.start(filePath, seekTime, { audioStreamIndex: currentAudioStreamIndex })
    currentSeekBase = seekTime

    return {
      streamUrl: 'stream://video',
      seekTime,
    }
  })

  // Switch audio track: restart ffmpeg at current position with different audio
  ipcMain.handle('playback:switchAudio', async (_e, audioStreamIndex, currentVideoTime) => {
    const filePath = transcoder.getActiveFilePath()
    if (!filePath) return { error: 'No active playback' }

    // Seek position = current seekBase + video element's currentTime
    const seekTime = currentSeekBase + (currentVideoTime || 0)
    currentAudioStreamIndex = audioStreamIndex

    transcoder.start(filePath, seekTime, { audioStreamIndex })
    currentSeekBase = seekTime

    return {
      streamUrl: 'stream://video',
      seekTime,
    }
  })

  // Switch subtitle track: re-extract a different subtitle or disable
  ipcMain.handle('playback:switchSubtitle', async (_e, subtitleStreamIndex) => {
    const filePath = transcoder.getActiveFilePath()
    if (!filePath) return { error: 'No active playback' }

    // Clear subtitle cache first
    try {
      const main = require('../main')
      main.setSubtitleCache(null)
    } catch {}

    // null or -1 means "off"
    if (subtitleStreamIndex == null || subtitleStreamIndex < 0) {
      return { subtitleUrl: null }
    }

    // Extract the requested subtitle track
    try {
      const vtt = await transcoder.extractSubtitles(filePath, subtitleStreamIndex)
      if (vtt) {
        try {
          const main = require('../main')
          main.setSubtitleCache(vtt)
        } catch (cacheErr) {
          console.error('[Subtitle] failed to set subtitle cache:', cacheErr)
        }
        return { subtitleUrl: 'subtitle://track?t=' + Date.now() }
      } else {
        console.warn('[Subtitle] extraction returned null for stream', subtitleStreamIndex)
      }
    } catch (extractErr) {
      console.error('[Subtitle] extraction error:', extractErr)
    }

    return { subtitleUrl: null }
  })

  // Stop playback and save final progress
  ipcMain.handle('playback:stop', (_e, finalTime, finalDuration) => {
    transcoder.stop()

    // Save final progress
    if (finalTime != null && finalDuration != null) {
      saveProgress(finalTime, finalDuration)
    }

    // Clear subtitle cache
    try {
      const main = require('../main')
      main.setSubtitleCache(null)
    } catch {}

    const result = {
      episodeId: currentEpisodeId,
      movieId: currentMovieId,
    }

    currentEpisodeId = null
    currentMovieId = null
    currentWatchHistoryId = null
    currentDuration = 0
    currentSeekBase = 0
    currentAudioStreamIndex = null

    return result
  })

  // Report progress from renderer (called on timeupdate, every ~3s)
  ipcMain.handle('playback:progress', (_e, videoTime, videoDuration) => {
    // videoTime is relative to the seek point, adjust to absolute
    const absoluteTime = currentSeekBase + videoTime
    const duration = currentDuration || videoDuration

    saveProgress(absoluteTime, duration)

    return { absoluteTime, duration }
  })

  // Set what's currently playing (called from episodes/movies IPC)
  ipcMain.handle('playback:setEpisode', (_e, episodeId, watchHistoryId) => {
    currentEpisodeId = episodeId
    currentMovieId = null
    currentWatchHistoryId = watchHistoryId
    return true
  })

  ipcMain.handle('playback:setMovie', (_e, movieId) => {
    currentMovieId = movieId
    currentEpisodeId = null
    currentWatchHistoryId = null
    return true
  })

  // Get current playback info (for NowPlaying bar)
  ipcMain.handle('playback:status', () => {
    const isTranscoding = transcoder.isActive()

    // Check in-app transcoder first
    if (isTranscoding) {
      if (currentEpisodeId) {
        const ep = db.episodes.findById(currentEpisodeId)
        const s = ep ? db.series.findById(ep.series_id) : null
        return {
          playing: true,
          source: 'inapp',
          type: 'episode',
          episode_id: currentEpisodeId,
          episode_title: ep?.title,
          episode_code: ep?.code,
          series_name: s?.name,
          series_slug: s?.slug,
        }
      }

      if (currentMovieId) {
        const movie = db.movies.findById(currentMovieId)
        return {
          playing: true,
          source: 'inapp',
          type: 'movie',
          movie_id: currentMovieId,
          movie_title: movie?.title,
          movie_slug: movie?.slug,
        }
      }

      return { playing: true, source: 'inapp' }
    }

    // Check VLC external playback
    if (vlcPollTimer) {
      if (vlcEpisodeId) {
        const ep = db.episodes.findById(vlcEpisodeId)
        const s = ep ? db.series.findById(ep.series_id) : null
        return {
          playing: true,
          source: 'vlc',
          type: 'episode',
          episode_id: vlcEpisodeId,
          episode_title: ep?.title,
          episode_code: ep?.code,
          series_name: s?.name,
          series_slug: s?.slug,
          time: vlcLastTime,
          duration: vlcLastLength,
        }
      }

      if (vlcMovieId) {
        const movie = db.movies.findById(vlcMovieId)
        return {
          playing: true,
          source: 'vlc',
          type: 'movie',
          movie_id: vlcMovieId,
          movie_title: movie?.title,
          movie_slug: movie?.slug,
          time: vlcLastTime,
          duration: vlcLastLength,
        }
      }

      return { playing: true, source: 'vlc', time: vlcLastTime, duration: vlcLastLength }
    }

    return { playing: false }
  })

  // Save playback preferences (audio/subtitle language) per series or movie
  ipcMain.handle('playback:savePreferences', (_e, { type, seriesId, movieId, audioLanguage, subtitleLanguage, subtitleOff, subtitleSize, subtitleStyle }) => {
    if (type === 'episode' && seriesId) {
      db.playbackPreferences.saveSeries(seriesId, {
        audio_language: audioLanguage,
        subtitle_language: subtitleLanguage,
        subtitle_off: subtitleOff,
        subtitle_size: subtitleSize,
        subtitle_style: subtitleStyle,
      })
    } else if (type === 'movie' && movieId) {
      db.playbackPreferences.saveMovie(movieId, {
        audio_language: audioLanguage,
        subtitle_language: subtitleLanguage,
        subtitle_off: subtitleOff,
        subtitle_size: subtitleSize,
        subtitle_style: subtitleStyle,
      })
    }
    return true
  })

  // Load playback preferences for a series or movie
  ipcMain.handle('playback:getPreferences', (_e, { type, seriesId, movieId }) => {
    let pref = null
    if (type === 'episode' && seriesId) {
      pref = db.playbackPreferences.forSeries(seriesId)
    } else if (type === 'movie' && movieId) {
      pref = db.playbackPreferences.forMovie(movieId)
    }
    if (!pref) return null
    return {
      audioLanguage: pref.audio_language,
      subtitleLanguage: pref.subtitle_language,
      subtitleOff: !!pref.subtitle_off,
      subtitleSize: pref.subtitle_size || 'medium',
      subtitleStyle: pref.subtitle_style || 'classic',
    }
  })

  // Check if VLC is installed
  ipcMain.handle('playback:checkVlc', () => {
    return fs.existsSync(VLC_APP_PATH)
  })

  // Open file in VLC with playback tracking via HTTP interface
  ipcMain.handle('playback:openInVlc', async (_e, { filePath, episodeId, movieId }) => {
    if (!fs.existsSync(VLC_APP_PATH)) {
      return { error: 'VLC is not installed. Install it from https://www.videolan.org/' }
    }
    if (!filePath || !fs.existsSync(filePath)) {
      return { error: 'File not found: ' + filePath }
    }

    // Stop any existing VLC polling
    stopVlcPolling()

    // Set up tracking context for new session
    vlcEpisodeId = episodeId || null
    vlcMovieId = movieId || null
    vlcWatchHistoryId = null
    vlcLastTime = 0
    vlcLastLength = 0

    // Create watch history entry for episodes
    if (vlcEpisodeId) {
      const episode = db.episodes.findById(vlcEpisodeId)
      if (episode) {
        // Mark prior episodes as watched
        db.episodes.markPriorWatched(episode.series_id, episode.season_number, episode.episode_number)
        db.episodes.markWatched(vlcEpisodeId)
        const wh = db.watchHistories.create({ episode_id: vlcEpisodeId })
        vlcWatchHistoryId = wh.id
      }
    }

    // Calculate resume position
    let startTime = 0
    if (vlcEpisodeId) {
      const ep = db.episodes.findById(vlcEpisodeId)
      if (ep && ep.progress_seconds > 0 && ep.duration_seconds > 0 &&
          (ep.progress_seconds / ep.duration_seconds) < 0.9) {
        startTime = ep.progress_seconds
      }
    } else if (vlcMovieId) {
      const mv = db.movies.findById(vlcMovieId)
      if (mv && mv.progress_seconds > 0 && mv.duration_seconds > 0 &&
          (mv.progress_seconds / mv.duration_seconds) < 0.9) {
        startTime = mv.progress_seconds
      }
    }

    try {
      // Check if VLC is already running with HTTP interface
      const running = await vlcRequest()

      if (running) {
        // Enqueue file into running VLC
        const fileUri = 'file://' + encodeURIComponent(filePath).replace(/%2F/g, '/').replace(/\+/g, '%20')
        await vlcRequest('?command=pl_empty')
        await vlcRequest(`?command=in_play&input=${fileUri}`)
        if (startTime > 0) {
          await new Promise(r => setTimeout(r, 500))
          await vlcRequest(`?command=seek&val=${startTime}`)
        }
      } else {
        // Launch VLC with HTTP interface
        const args = [
          filePath,
          '--extraintf', 'http',
          '--http-port', String(VLC_HTTP_PORT),
          '--http-password', VLC_HTTP_PASSWORD,
          '--no-http-forward-cookies',
        ]
        if (startTime > 0) {
          args.push('--start-time', String(startTime))
        }
        const child = spawn(VLC_BIN_PATH, args, {
          detached: true,
          stdio: 'ignore',
        })
        child.unref()
      }

      // Start polling after a short delay (give VLC time to start)
      setTimeout(() => startVlcPolling(), 2000)

      return { ok: true }
    } catch (err) {
      return { error: err.message }
    }
  })

  // Open file in default OS player
  ipcMain.handle('playback:openInDefault', async (_e, filePath) => {
    if (!filePath || !fs.existsSync(filePath)) {
      return { error: 'File not found: ' + filePath }
    }
    try {
      const result = await shell.openPath(filePath)
      // shell.openPath returns empty string on success, error string on failure
      if (result) {
        return { error: result }
      }
      return { ok: true }
    } catch (err) {
      return { error: err.message }
    }
  })
}

function saveProgress(time, duration) {
  if (currentEpisodeId && duration > 0) {
    db.episodes.updateProgress(currentEpisodeId, Math.round(time), Math.round(duration))
    if (currentWatchHistoryId) {
      db.watchHistories.updateProgress(currentWatchHistoryId, Math.round(time), Math.round(duration))
    }
    // Auto-mark watched at 90%
    if (time / duration >= 0.9) {
      db.episodes.markWatched(currentEpisodeId)
    }
  }

  if (currentMovieId && duration > 0) {
    db.movies.updateProgress(currentMovieId, Math.round(time), Math.round(duration))
    if (time / duration >= 0.9) {
      db.movies.markWatched(currentMovieId)
    }
  }
}

function getCurrentSeekBase() { return currentSeekBase }

// -- VLC HTTP interface helpers --

async function vlcRequest(queryPath = '') {
  const url = `http://localhost:${VLC_HTTP_PORT}/requests/status.json${queryPath}`
  try {
    const res = await fetch(url, {
      headers: { Authorization: VLC_AUTH_HEADER },
      signal: AbortSignal.timeout(3000),
    })
    if (!res.ok) return null
    return await res.json()
  } catch {
    return null
  }
}

function saveVlcProgress(time, duration) {
  if (vlcEpisodeId && duration > 0) {
    db.episodes.updateProgress(vlcEpisodeId, Math.round(time), Math.round(duration))
    if (vlcWatchHistoryId) {
      db.watchHistories.updateProgress(vlcWatchHistoryId, Math.round(time), Math.round(duration))
    }
    if (time / duration >= 0.9) {
      db.episodes.markWatched(vlcEpisodeId)
    }
  }
  if (vlcMovieId && duration > 0) {
    db.movies.updateProgress(vlcMovieId, Math.round(time), Math.round(duration))
    if (time / duration >= 0.9) {
      db.movies.markWatched(vlcMovieId)
    }
  }
}

function startVlcPolling() {
  // Only clear the timer, not the tracking state
  if (vlcPollTimer) {
    clearInterval(vlcPollTimer)
    vlcPollTimer = null
  }
  vlcPollTimer = setInterval(async () => {
    const data = await vlcRequest()
    if (!data || data.state === 'stopped') {
      // VLC stopped or closed — save final progress and clean up
      if (vlcLastTime > 0 && vlcLastLength > 0) {
        saveVlcProgress(vlcLastTime, vlcLastLength)
      }
      clearVlcState()
      // Notify renderer to refresh data
      try {
        const { BrowserWindow } = require('electron')
        const win = BrowserWindow.getAllWindows()[0]
        if (win) win.webContents.send('vlc-playback-ended')
      } catch {}
      return
    }
    const time = parseInt(data.time) || 0
    const length = parseInt(data.length) || 0
    if (time > 0 && length > 0) {
      vlcLastTime = time
      vlcLastLength = length
      saveVlcProgress(time, length)
    }
  }, VLC_POLL_INTERVAL)
}

function stopVlcPolling() {
  if (vlcPollTimer) {
    clearInterval(vlcPollTimer)
    vlcPollTimer = null
  }
}

function clearVlcState() {
  stopVlcPolling()
  vlcEpisodeId = null
  vlcMovieId = null
  vlcWatchHistoryId = null
  vlcLastTime = 0
  vlcLastLength = 0
}

module.exports = { register, getCurrentSeekBase }
