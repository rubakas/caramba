// IPC handler for in-app video playback via ffmpeg transcoder.
// Replaces VLC-based polling with transcoder + HTML5 <video> approach.
// External VLC control is delegated to the libvlc-player service.

const { ipcMain, shell } = require('electron')
const fs = require('fs')
const db = require('../db')
const transcoder = require('../services/transcoder')
const apiConfig = require('../services/api-config')
const libvlc = require('../services/libvlc-player')
const { selectAudioTrack, selectSubtitleTrack } = require('../services/track-selection')
const { resolvePlaybackPath } = require('./downloads')

// VLC external playback tracking state — bookkeeping that ties VLC's playback
// session to a specific episode/movie. The playback details (time, length,
// state) live in libvlc-player.
let vlcEpisodeId = null
let vlcMovieId = null
let vlcWatchHistoryId = null

// Tracked playback state
let currentEpisodeId = null
let currentMovieId = null
let currentWatchHistoryId = null
let currentDuration = 0
let currentSeekBase = 0 // the -ss offset used when starting ffmpeg
let currentAudioStreamIndex = null // preferred audio stream index
let currentBurnSubtitleIndex = null // bitmap subtitle being burned into video (null = none)

function register() {
  // Start playback: probe file, start transcoder, extract subs
  ipcMain.handle('playback:start', async (_e, filePath, startTime = 0, prefs = null, options = null) => {
    try {
      if (!filePath || !fs.existsSync(filePath)) {
        return { error: 'File not found: ' + (filePath || '(no path)') }
      }

      // Security: only allow playback of files within registered media directories.
      // Skip this check when server mode is enabled — the server already validated
      // the path, and we're just using local transcoding for performance.
      if (!apiConfig.isEnabled() && !db.isKnownMediaPath(filePath)) {
        return { error: 'File is not in a registered media directory' }
      }

      // Prefer cached probe data on the Episode/Movie row (written at
      // scan time by tech-probe.js). Falls back to a live ffprobe when
      // missing or the file size has changed.
      const techProbe = require('../services/tech-probe')
      const cachedRecord =
        db.episodes.findByFilePath?.(filePath) ||
        db.movies.findByFilePath?.(filePath)
      const cachedInfo = cachedRecord ? await techProbe.probeFor(cachedRecord) : null
      const info = cachedInfo || await transcoder.probe(filePath)

      const audioStreamIndex = selectAudioTrack(info.audioStreams, prefs)
      const sub = selectSubtitleTrack(info.subtitleStreams, prefs)
      const subtitleStreamIndex = sub.index
      const isBitmapSubtitle = sub.isBitmap

      // Start transcoding — burn bitmap subtitles into video if selected.
      // Pass the probe result we already computed so transcoder.start()
      // doesn't re-probe the file.
      const startResult = await transcoder.start(filePath, startTime, {
        audioStreamIndex,
        burnSubtitleIndex: isBitmapSubtitle ? subtitleStreamIndex : undefined,
        probeResult: info,
        forceTranscode: !!options?.forceTranscode,
      })
      currentSeekBase = startTime
      currentDuration = info.duration
      currentAudioStreamIndex = audioStreamIndex
      currentBurnSubtitleIndex = isBitmapSubtitle ? subtitleStreamIndex : null

      // direct_play: stream the file as-is. Renderer skips hls.js and
      // points <video> at stream://direct, which main.js serves with
      // Range support. The startTime is conveyed via the URL so the
      // renderer can seek the <video> element after metadata loads.
      const isDirectPlay = startResult.strategy === 'direct_play'
      const streamUrl = isDirectPlay
        ? `stream://direct/file?t=${Date.now()}&start=${startTime}`
        : 'stream://video/playlist.m3u8?t=' + Date.now()

      // Extract text subtitles in the background (non-blocking).
      // The video starts playing immediately; subtitles arrive asynchronously
      // via a push event once extraction finishes.
      // (bitmap subtitles are already burned in — no extraction needed)
      if (subtitleStreamIndex != null && !isBitmapSubtitle) {
        transcoder.extractSubtitles(filePath, subtitleStreamIndex)
          .then(vtt => {
            if (!vtt) return
            const main = require('../main')
            main.setSubtitleCache(vtt)
            const url = 'subtitle://track?t=' + Date.now()
            // Push subtitle URL to renderer
            try {
              const { BrowserWindow } = require('electron')
              const win = BrowserWindow.getAllWindows()[0]
              if (win) win.webContents.send('playback:subtitles-ready', { subtitleUrl: url, subtitleStreamIndex })
            } catch {}
          })
          .catch(err => {
            console.error('[Subtitle] background extraction failed:', err)
          })
      }

      return {
        streamUrl,
        duration: info.duration,
        startTime,
        // direct_play: seekBase is 0 because <video>.currentTime *is* the
        // absolute timeline position. For ffmpeg-fed strategies seekBase
        // tracks the -ss offset so display time = seekBase + currentTime.
        seekBase: isDirectPlay ? 0 : startTime,
        subtitleUrl: null, // subtitles arrive asynchronously
        video: info.video,
        audioStreams: info.audioStreams,
        subtitleStreams: info.subtitleStreams,
        activeAudioIndex: audioStreamIndex,
        activeSubtitleIndex: subtitleStreamIndex,
        isBitmapSubtitle,
        strategy: startResult.strategy,
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

    const seekResult = await transcoder.start(filePath, seekTime, {
      audioStreamIndex: currentAudioStreamIndex,
      burnSubtitleIndex: currentBurnSubtitleIndex ?? undefined,
      forceTranscode: transcoder.getActiveForceTranscode(),
    })
    currentSeekBase = seekTime

    return {
      streamUrl: 'stream://video/playlist.m3u8?t=' + Date.now(),
      seekTime,
      strategy: seekResult.strategy,
    }
  })

  // Switch audio track: restart ffmpeg at current position with different audio
  ipcMain.handle('playback:switchAudio', async (_e, audioStreamIndex, currentVideoTime) => {
    const filePath = transcoder.getActiveFilePath()
    if (!filePath) return { error: 'No active playback' }

    // Seek position = current seekBase + video element's currentTime
    const seekTime = currentSeekBase + (currentVideoTime || 0)
    currentAudioStreamIndex = audioStreamIndex

    const switchResult = await transcoder.start(filePath, seekTime, {
      audioStreamIndex,
      burnSubtitleIndex: currentBurnSubtitleIndex ?? undefined,
      forceTranscode: transcoder.getActiveForceTranscode(),
    })
    currentSeekBase = seekTime

    return {
      streamUrl: 'stream://video/playlist.m3u8?t=' + Date.now(),
      seekTime,
      strategy: switchResult.strategy,
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

  // Switch bitmap subtitle: restart ffmpeg with or without overlay burn-in.
  // This works like audio switching — it restarts the transcode at the current position.
  ipcMain.handle('playback:switchBitmapSubtitle', async (_e, subtitleStreamIndex, currentVideoTime) => {
    const filePath = transcoder.getActiveFilePath()
    if (!filePath) return { error: 'No active playback' }

    // Clear text subtitle cache (bitmap subs replace text subs)
    try {
      const main = require('../main')
      main.setSubtitleCache(null)
    } catch {}

    const seekTime = currentSeekBase + (currentVideoTime || 0)
    currentBurnSubtitleIndex = subtitleStreamIndex // null = off

    const bitmapResult = await transcoder.start(filePath, seekTime, {
      audioStreamIndex: currentAudioStreamIndex,
      burnSubtitleIndex: subtitleStreamIndex ?? undefined,
      forceTranscode: transcoder.getActiveForceTranscode(),
    })
    currentSeekBase = seekTime

    return {
      streamUrl: 'stream://video/playlist.m3u8?t=' + Date.now(),
      seekTime,
      strategy: bitmapResult.strategy,
    }
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
    currentBurnSubtitleIndex = null

    return result
  })

  // Report progress from renderer (called on timeupdate, every ~3s)
  ipcMain.handle('playback:progress', (_e, videoTime, videoDuration) => {
    // videoTime is already absolute (seekBase + video.currentTime),
    // computed by the renderer before sending.
    const absoluteTime = videoTime
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
        const s = ep ? db.shows.findById(ep.show_id) : null
        return {
          playing: true,
          source: 'inapp',
          type: 'episode',
          episode_id: currentEpisodeId,
          episode_title: ep?.title,
          episode_code: ep?.code,
          show_name: s?.name,
          show_slug: s?.slug,
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
    const tick = libvlc.lastTick()
    if (tick) {
      const time = tick.time
      const duration = tick.length
      if (vlcEpisodeId) {
        const ep = db.episodes.findById(vlcEpisodeId)
        const s = ep ? db.shows.findById(ep.show_id) : null
        return {
          playing: true,
          source: 'vlc',
          type: 'episode',
          episode_id: vlcEpisodeId,
          episode_title: ep?.title,
          episode_code: ep?.code,
          show_name: s?.name,
          show_slug: s?.slug,
          time,
          duration,
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
          time,
          duration,
        }
      }

      return { playing: true, source: 'vlc', time, duration }
    }

    return { playing: false }
  })

  // Save playback preferences (audio/subtitle language) per show or movie
  ipcMain.handle('playback:savePreferences', (_e, { type, showId, movieId, audioLanguage, subtitleLanguage, subtitleOff, subtitleSize, subtitleStyle }) => {
    if (type === 'episode' && showId) {
      db.playbackPreferences.saveShow(showId, {
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

  // Load playback preferences for a show or movie
  ipcMain.handle('playback:getPreferences', (_e, { type, showId, movieId }) => {
    let pref = null
    if (type === 'episode' && showId) {
      pref = db.playbackPreferences.forShow(showId)
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
  ipcMain.handle('playback:checkVlc', () => libvlc.isInstalled())

  // Open file in VLC with playback tracking via libvlc-player service
  ipcMain.handle('playback:openInVlc', async (_e, { filePath, episodeId, movieId }) => {
    if (!libvlc.isInstalled()) {
      return { error: 'VLC is not installed. Install it from https://www.videolan.org/' }
    }

    // Resolve file path: prefer downloaded copy, fall back to original
    const resolvedPath = resolvePlaybackPath(filePath, episodeId || null, movieId || null)
    if (!resolvedPath) {
      return { error: 'File not found: ' + filePath }
    }
    // Security: only allow opening files within registered media directories.
    // Skip when server mode is enabled — server already validated the path.
    if (!apiConfig.isEnabled() && !db.isKnownMediaPath(resolvedPath)) {
      return { error: 'File is not in a registered media directory' }
    }

    // Reset session state for new playback
    libvlc.stopPolling()
    vlcEpisodeId = episodeId || null
    vlcMovieId = movieId || null
    vlcWatchHistoryId = null

    // Create watch history entry for episodes
    if (vlcEpisodeId) {
      const episode = db.episodes.findById(vlcEpisodeId)
      if (episode) {
        // Mark prior episodes as watched
        db.episodes.markPriorWatched(episode.show_id, episode.season_number, episode.episode_number)
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
      await libvlc.play(resolvedPath, startTime)
      // Wait briefly for VLC to settle, then begin polling for progress.
      setTimeout(() => libvlc.startPolling(), 2000)
      return { ok: true }
    } catch (err) {
      return { error: err.message }
    }
  })

  // libvlc library control surface — fine-grained playback commands the
  // renderer can issue for VLC sessions started via openInVlc.
  ipcMain.handle('libvlc:status', async () => {
    try { return await libvlc.status() } catch { return null }
  })
  ipcMain.handle('libvlc:pause', async () => {
    try { await libvlc.pause(); return { ok: true } } catch (err) { return { error: err.message } }
  })
  ipcMain.handle('libvlc:resume', async () => {
    try { await libvlc.resume(); return { ok: true } } catch (err) { return { error: err.message } }
  })
  ipcMain.handle('libvlc:stop', async () => {
    try { await libvlc.stop(); libvlc.stopPolling(); return { ok: true } } catch (err) { return { error: err.message } }
  })
  ipcMain.handle('libvlc:seek', async (_e, seconds) => {
    try { await libvlc.seek(seconds); return { ok: true } } catch (err) { return { error: err.message } }
  })
  ipcMain.handle('libvlc:setVolume', async (_e, level) => {
    try { await libvlc.setVolume(level); return { ok: true } } catch (err) { return { error: err.message } }
  })

  // Open file in default OS player
  ipcMain.handle('playback:openInDefault', async (_e, filePath, episodeId, movieId) => {
    // Resolve file path: prefer downloaded copy, fall back to original
    const resolvedPath = resolvePlaybackPath(filePath, episodeId || null, movieId || null)
    if (!resolvedPath) {
      return { error: 'File not found: ' + filePath }
    }
    // Security: only allow opening files within registered media directories.
    // Skip when server mode is enabled — server already validated the path.
    if (!apiConfig.isEnabled() && !db.isKnownMediaPath(resolvedPath)) {
      return { error: 'File is not in a registered media directory' }
    }
    try {
      const result = await shell.openPath(resolvedPath)
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

// -- VLC session bridge --
//
// libvlc-player owns the polling loop and emits 'tick' / 'ended' events.
// Here we tie those events to per-card progress writes and the renderer
// notification, then clear our local episode/movie/history bookkeeping.

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

libvlc.events.on('tick', ({ time, length }) => {
  if (time > 0 && length > 0) saveVlcProgress(time, length)
})

libvlc.events.on('ended', (final) => {
  if (final && final.time > 0 && final.length > 0) {
    saveVlcProgress(final.time, final.length)
  }
  vlcEpisodeId = null
  vlcMovieId = null
  vlcWatchHistoryId = null
  try {
    const { BrowserWindow } = require('electron')
    const win = BrowserWindow.getAllWindows()[0]
    if (win) win.webContents.send('vlc-playback-ended')
  } catch {}
})

module.exports = { register, getCurrentSeekBase }
