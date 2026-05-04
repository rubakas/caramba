// IPC handler for in-app video playback via the embedded libVLC.
//
// libVLC runs in-process (electron/native/vlc-embed) and renders directly
// into the BrowserWindow's content NSView. The renderer's React UI is the
// transparent overlay on top — single OS window, full libVLC codec coverage,
// no server transcoding, no HLS, no <video> element.
//
// External VLC control (the "Open in VLC" feature) still lives here and is
// delegated to libvlc-player.js (subprocess + HTTP control).

const { ipcMain, shell, BrowserWindow } = require('electron')
const fs = require('fs')
const db = require('../db')
const vlcEmbed = require('../services/vlc-embed-player')
const transcoder = require('../services/transcoder')
const techProbe = require('../services/tech-probe')
const apiConfig = require('../services/api-config')
const libvlc = require('../services/libvlc-player')
const { resolvePlaybackPath } = require('./downloads')

// External-VLC bookkeeping (unchanged).
let vlcEpisodeId = null
let vlcMovieId = null
let vlcWatchHistoryId = null

// In-app playback bookkeeping.
let currentEpisodeId = null
let currentMovieId = null
let currentWatchHistoryId = null
let currentDuration = 0
let currentFilePath = null
let lastReportedTime = 0
let lastProbeAudio = []
let lastProbeSubtitle = []

function broadcast(channel, payload) {
  for (const win of BrowserWindow.getAllWindows()) {
    if (!win.isDestroyed()) win.webContents.send(channel, payload)
  }
}

// Map saved prefs (audioLanguage / subtitleLanguage / subtitleOff) to libvlc
// track IDs. libvlc returns tracks as { id, name } where `name` typically
// contains a language code like "Track 1 - [English]".
function pickAudioId(audioTracks, prefs) {
  if (!audioTracks?.length) return null
  if (prefs?.audioLanguage) {
    const lang = prefs.audioLanguage.toLowerCase()
    const hit = audioTracks.find(t => (t.name || '').toLowerCase().includes(lang))
    if (hit && hit.id !== -1) return hit.id
  }
  // libvlc has a special id=-1 "Disable" entry; pick the first real track.
  const real = audioTracks.find(t => t.id !== -1)
  return real ? real.id : null
}
function pickSubtitleId(subtitleTracks, prefs) {
  if (prefs?.subtitleOff) return -1
  if (!subtitleTracks?.length) return -1
  if (prefs?.subtitleLanguage) {
    const lang = prefs.subtitleLanguage.toLowerCase()
    const hit = subtitleTracks.find(t => t.id !== -1 && (t.name || '').toLowerCase().includes(lang))
    if (hit) return hit.id
  }
  return -1   // default to off; user picks via UI
}

// Renderer expects audioStreams/subtitleStreams in the HLS shape
// ({ id, language, codec, channels, title }). libvlc only gives us
// { id, name }, so we enrich from ffprobe — both come from libavformat,
// so the (filtered) lists are in the same container order and can be
// zipped by position. The libvlc id stays as the switch key.
function reshapeWithProbe(rawTracks, probeStreams) {
  const real = (rawTracks || []).filter(t => t.id !== -1)
  return real.map((t, i) => {
    const probe = probeStreams?.[i] || {}
    return {
      id: t.id,                                                // libvlc switch key
      title: probe.title || t.name || null,
      language: probe.language && probe.language !== 'und' ? probe.language : null,
      codec: probe.codec || null,
      channels: probe.channels ?? null,
    }
  })
}

function register(mainWindow) {
  // Initialize libvlc once we have the BrowserWindow's NSView handle.
  // Lazy init so module load doesn't fail when vlc isn't set up yet.
  let initPromise = null
  function ensureInit() {
    if (initPromise) return initPromise
    initPromise = (async () => {
      if (!vlcEmbed.isAvailable()) {
        throw new Error('libVLC embed not available — run desktop/bin/setup-vlc')
      }
      vlcEmbed.init(mainWindow.getNativeWindowHandle())
    })()
    return initPromise
  }

  // Forward libvlc state pushes to every renderer window.
  vlcEmbed.events.on('state', s => {
    lastReportedTime = s.time || 0
    if (s.duration > 0) currentDuration = s.duration
    broadcast('playback:state', s)
  })
  vlcEmbed.events.on('tracks', t => {
    broadcast('playback:tracks', {
      audio: reshapeWithProbe(t.audio, lastProbeAudio),
      subtitle: reshapeWithProbe(t.subtitle, lastProbeSubtitle),
    })
  })
  vlcEmbed.events.on('ended', e => {
    if (e?.duration > 0) saveProgress(e.time, e.duration)
    broadcast('playback:ended', e)
  })

  // Start playback: open the file in libvlc and apply saved prefs once
  // the first track-list arrives.
  ipcMain.handle('playback:start', async (_e, filePath, startTime = 0, prefs = null, _options = null) => {
    try {
      if (!filePath || !fs.existsSync(filePath)) {
        return { error: 'File not found: ' + (filePath || '(no path)') }
      }
      if (!apiConfig.isEnabled() && !db.isKnownMediaPath(filePath)) {
        return { error: 'File is not in a registered media directory' }
      }

      // Run ffprobe up front. Gives us video codec/res/HDR info for the
      // dev overlay AND audio/subtitle stream metadata (codec, channels,
      // language) which libvlc's track API doesn't expose.
      const cachedRecord =
        db.episodes.findByFilePath?.(filePath) ||
        db.movies.findByFilePath?.(filePath)
      let probeInfo = null
      if (cachedRecord) {
        probeInfo = await techProbe.probeFor(cachedRecord).catch(() => null)
      }
      if (!probeInfo) {
        probeInfo = await transcoder.probe(filePath).catch(() => null)
      }
      lastProbeAudio = probeInfo?.audioStreams || []
      lastProbeSubtitle = probeInfo?.subtitleStreams || []

      await ensureInit()
      await vlcEmbed.start(filePath, startTime)
      currentFilePath = filePath
      lastReportedTime = startTime

      // libvlc populates the track list asynchronously after open. Wait
      // through several poll intervals so we capture the full set, not the
      // half-loaded "Disable + first track" snapshot that fires within
      // the first ~100 ms.
      let tracks = { audio: [], subtitle: [] }
      for (let i = 0; i < 30; i++) {
        await new Promise(r => setTimeout(r, 100))
        tracks = vlcEmbed.getTracks()
        const real = (tracks.audio || []).filter(t => t.id !== -1)
        if (real.length > 0) break
      }

      const audio = reshapeWithProbe(tracks.audio, lastProbeAudio)
      const subtitle = reshapeWithProbe(tracks.subtitle, lastProbeSubtitle)

      // Apply prefs on the libvlc native track ids.
      const aId = pickAudioId(tracks.audio, prefs)
      const sId = pickSubtitleId(tracks.subtitle, prefs)
      if (aId != null) vlcEmbed.setAudioTrack(aId)
      vlcEmbed.setSubtitleTrack(sId)

      const state = vlcEmbed.getState()
      currentDuration = state.duration || 0

      // Strategy label for the dev overlay. libvlc plays MKV directly →
      // direct_play; remuxing to MP4 isn't a thing in this engine. Keep
      // direct_stream for non-MP4 containers so the badge tells the user
      // the video is being demuxed inline (matches the web vocabulary).
      const isMp4 = (probeInfo?.formatName || '').toLowerCase().includes('mp4')
      const strategy = isMp4 ? 'direct_play' : 'direct_stream'

      return {
        duration: currentDuration,
        startTime,
        audioStreams: audio,
        subtitleStreams: subtitle,
        activeAudioIndex: aId,
        activeSubtitleIndex: sId === -1 ? null : sId,
        isBitmapSubtitle: false,
        video: probeInfo?.video || null,
        bitrate: probeInfo?.bitrate || null,
        strategy,
      }
    } catch (err) {
      console.error('playback:start error:', err)
      return { error: err.message }
    }
  })

  ipcMain.handle('playback:seek', async (_e, seekTime) => {
    if (!vlcEmbed.isPlaying()) return { error: 'No active playback' }
    try {
      await vlcEmbed.seek(Number(seekTime) || 0)
      return { ok: true, seekTime }
    } catch (err) { return { error: err.message } }
  })

  ipcMain.handle('playback:pause',  async () => { try { await vlcEmbed.pause();  return { ok: true } } catch (err) { return { error: err.message } } })
  ipcMain.handle('playback:resume', async () => { try { await vlcEmbed.resume(); return { ok: true } } catch (err) { return { error: err.message } } })

  ipcMain.handle('playback:switchAudio', async (_e, audioStreamId) => {
    try { vlcEmbed.setAudioTrack(audioStreamId); return { ok: true, audioStreamId } }
    catch (err) { return { error: err.message } }
  })

  ipcMain.handle('playback:switchSubtitle', async (_e, subtitleStreamId) => {
    try {
      const id = (subtitleStreamId == null || subtitleStreamId < 0) ? -1 : subtitleStreamId
      vlcEmbed.setSubtitleTrack(id)
      return { ok: true, subtitleStreamId: id === -1 ? null : id }
    } catch (err) { return { error: err.message } }
  })

  // External-subtitle add and subtitle-appearance live for parity with the
  // adapter API, but libvlc 3.x's external sub support and styling knobs are
  // limited. Wire them as no-ops for now; we'll fill in if there's demand.
  ipcMain.handle('playback:addExternalSubtitle', async () => ({ ok: true }))
  ipcMain.handle('playback:setSubtitleAppearance', async () => ({ ok: true }))

  ipcMain.handle('playback:stop', async (_e, finalTime, finalDuration) => {
    try { await vlcEmbed.stop() } catch {}
    if (finalTime != null && finalDuration != null) saveProgress(finalTime, finalDuration)

    const result = { episodeId: currentEpisodeId, movieId: currentMovieId }
    currentEpisodeId = null
    currentMovieId = null
    currentWatchHistoryId = null
    currentDuration = 0
    currentFilePath = null
    lastReportedTime = 0
    lastProbeAudio = []
    lastProbeSubtitle = []
    return result
  })

  ipcMain.handle('playback:progress', (_e, time, duration) => {
    const t = Number(time) || 0
    const d = Number(duration) || currentDuration
    saveProgress(t, d)
    return { absoluteTime: t, duration: d }
  })

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

  ipcMain.handle('playback:status', () => {
    if (vlcEmbed.isPlaying()) {
      if (currentEpisodeId) {
        const ep = db.episodes.findById(currentEpisodeId)
        const s = ep ? db.shows.findById(ep.show_id) : null
        return {
          playing: true, source: 'inapp', type: 'episode',
          episode_id: currentEpisodeId, episode_title: ep?.title, episode_code: ep?.code,
          show_name: s?.name, show_slug: s?.slug,
          time: lastReportedTime, duration: currentDuration,
        }
      }
      if (currentMovieId) {
        const movie = db.movies.findById(currentMovieId)
        return {
          playing: true, source: 'inapp', type: 'movie',
          movie_id: currentMovieId, movie_title: movie?.title, movie_slug: movie?.slug,
          time: lastReportedTime, duration: currentDuration,
        }
      }
      return { playing: true, source: 'inapp', time: lastReportedTime, duration: currentDuration }
    }

    const tick = libvlc.lastTick()
    if (tick) {
      const time = tick.time, duration = tick.length
      if (vlcEpisodeId) {
        const ep = db.episodes.findById(vlcEpisodeId)
        const s = ep ? db.shows.findById(ep.show_id) : null
        return { playing: true, source: 'vlc', type: 'episode',
          episode_id: vlcEpisodeId, episode_title: ep?.title, episode_code: ep?.code,
          show_name: s?.name, show_slug: s?.slug, time, duration }
      }
      if (vlcMovieId) {
        const movie = db.movies.findById(vlcMovieId)
        return { playing: true, source: 'vlc', type: 'movie',
          movie_id: vlcMovieId, movie_title: movie?.title, movie_slug: movie?.slug, time, duration }
      }
      return { playing: true, source: 'vlc', time, duration }
    }
    return { playing: false }
  })

  // Preferences (DB shape unchanged).
  ipcMain.handle('playback:savePreferences', (_e, { type, showId, movieId, audioLanguage, subtitleLanguage, subtitleOff, subtitleSize, subtitleStyle }) => {
    if (type === 'episode' && showId) {
      db.playbackPreferences.saveShow(showId, {
        audio_language: audioLanguage, subtitle_language: subtitleLanguage, subtitle_off: subtitleOff,
        subtitle_size: subtitleSize, subtitle_style: subtitleStyle,
      })
    } else if (type === 'movie' && movieId) {
      db.playbackPreferences.saveMovie(movieId, {
        audio_language: audioLanguage, subtitle_language: subtitleLanguage, subtitle_off: subtitleOff,
        subtitle_size: subtitleSize, subtitle_style: subtitleStyle,
      })
    }
    return true
  })
  ipcMain.handle('playback:getPreferences', (_e, { type, showId, movieId }) => {
    let pref = null
    if (type === 'episode' && showId) pref = db.playbackPreferences.forShow(showId)
    else if (type === 'movie' && movieId) pref = db.playbackPreferences.forMovie(movieId)
    if (!pref) return null
    return {
      audioLanguage: pref.audio_language, subtitleLanguage: pref.subtitle_language,
      subtitleOff: !!pref.subtitle_off,
      subtitleSize: pref.subtitle_size || 'medium',
      subtitleStyle: pref.subtitle_style || 'classic',
    }
  })

  // ── External VLC bridge (unchanged) ───────────────────────────
  ipcMain.handle('playback:checkVlc', () => libvlc.isInstalled())
  ipcMain.handle('playback:openInVlc', async (_e, { filePath, episodeId, movieId }) => {
    if (!libvlc.isInstalled()) {
      return { error: 'VLC is not installed. Install it from https://www.videolan.org/' }
    }
    const resolvedPath = resolvePlaybackPath(filePath, episodeId || null, movieId || null)
    if (!resolvedPath) return { error: 'File not found: ' + filePath }
    if (!apiConfig.isEnabled() && !db.isKnownMediaPath(resolvedPath)) {
      return { error: 'File is not in a registered media directory' }
    }
    libvlc.stopPolling()
    vlcEpisodeId = episodeId || null
    vlcMovieId = movieId || null
    vlcWatchHistoryId = null
    if (vlcEpisodeId) {
      const episode = db.episodes.findById(vlcEpisodeId)
      if (episode) {
        db.episodes.markPriorWatched(episode.show_id, episode.season_number, episode.episode_number)
        db.episodes.markWatched(vlcEpisodeId)
        const wh = db.watchHistories.create({ episode_id: vlcEpisodeId })
        vlcWatchHistoryId = wh.id
      }
    }
    let startTime = 0
    if (vlcEpisodeId) {
      const ep = db.episodes.findById(vlcEpisodeId)
      if (ep && ep.progress_seconds > 0 && ep.duration_seconds > 0 &&
          (ep.progress_seconds / ep.duration_seconds) < 0.9) startTime = ep.progress_seconds
    } else if (vlcMovieId) {
      const mv = db.movies.findById(vlcMovieId)
      if (mv && mv.progress_seconds > 0 && mv.duration_seconds > 0 &&
          (mv.progress_seconds / mv.duration_seconds) < 0.9) startTime = mv.progress_seconds
    }
    try {
      await libvlc.play(resolvedPath, startTime)
      setTimeout(() => libvlc.startPolling(), 2000)
      return { ok: true }
    } catch (err) { return { error: err.message } }
  })

  ipcMain.handle('libvlc:status', async () => { try { return await libvlc.status() } catch { return null } })
  ipcMain.handle('libvlc:pause',  async () => { try { await libvlc.pause();  return { ok: true } } catch (err) { return { error: err.message } } })
  ipcMain.handle('libvlc:resume', async () => { try { await libvlc.resume(); return { ok: true } } catch (err) { return { error: err.message } } })
  ipcMain.handle('libvlc:stop',   async () => { try { await libvlc.stop(); libvlc.stopPolling(); return { ok: true } } catch (err) { return { error: err.message } } })
  ipcMain.handle('libvlc:seek',   async (_e, seconds) => { try { await libvlc.seek(seconds); return { ok: true } } catch (err) { return { error: err.message } } })
  ipcMain.handle('libvlc:setVolume', async (_e, level) => { try { await libvlc.setVolume(level); return { ok: true } } catch (err) { return { error: err.message } } })

  ipcMain.handle('playback:openInDefault', async (_e, filePath, episodeId, movieId) => {
    const resolvedPath = resolvePlaybackPath(filePath, episodeId || null, movieId || null)
    if (!resolvedPath) return { error: 'File not found: ' + filePath }
    if (!apiConfig.isEnabled() && !db.isKnownMediaPath(resolvedPath)) {
      return { error: 'File is not in a registered media directory' }
    }
    try {
      const result = await shell.openPath(resolvedPath)
      if (result) return { error: result }
      return { ok: true }
    } catch (err) { return { error: err.message } }
  })
}

function saveProgress(time, duration) {
  if (currentEpisodeId && duration > 0) {
    db.episodes.updateProgress(currentEpisodeId, Math.round(time), Math.round(duration))
    if (currentWatchHistoryId) {
      db.watchHistories.updateProgress(currentWatchHistoryId, Math.round(time), Math.round(duration))
    }
    if (time / duration >= 0.9) db.episodes.markWatched(currentEpisodeId)
  }
  if (currentMovieId && duration > 0) {
    db.movies.updateProgress(currentMovieId, Math.round(time), Math.round(duration))
    if (time / duration >= 0.9) db.movies.markWatched(currentMovieId)
  }
}

function saveVlcProgress(time, duration) {
  if (vlcEpisodeId && duration > 0) {
    db.episodes.updateProgress(vlcEpisodeId, Math.round(time), Math.round(duration))
    if (vlcWatchHistoryId) db.watchHistories.updateProgress(vlcWatchHistoryId, Math.round(time), Math.round(duration))
    if (time / duration >= 0.9) db.episodes.markWatched(vlcEpisodeId)
  }
  if (vlcMovieId && duration > 0) {
    db.movies.updateProgress(vlcMovieId, Math.round(time), Math.round(duration))
    if (time / duration >= 0.9) db.movies.markWatched(vlcMovieId)
  }
}

libvlc.events.on('tick', ({ time, length }) => {
  if (time > 0 && length > 0) saveVlcProgress(time, length)
})
libvlc.events.on('ended', (final) => {
  if (final && final.time > 0 && final.length > 0) saveVlcProgress(final.time, final.length)
  vlcEpisodeId = null; vlcMovieId = null; vlcWatchHistoryId = null
  try {
    const win = BrowserWindow.getAllWindows()[0]
    if (win) win.webContents.send('vlc-playback-ended')
  } catch {}
})

module.exports = { register }
