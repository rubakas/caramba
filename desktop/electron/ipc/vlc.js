// IPC handlers for VLC playback in the desktop app.
//
// Two surfaces:
//   1. Embedded libVLC — the native engine renders directly into the
//      BrowserWindow's NSView. The renderer uses this engine when the user
//      picks "Embedded VLC" in Settings.
//   2. External VLC subprocess — the "Open in VLC" feature launches a
//      separate VLC process and controls it over its HTTP interface.
//
// Both consume server-provided HLS URLs. There is no local SQLite, no local
// transcoder, no local file resolution — those all live on the server now.

const { ipcMain, shell, BrowserWindow, powerSaveBlocker } = require('electron')
const vlcEmbed = require('../services/vlc-embed-player')
const libvlc = require('../services/libvlc-player')

// External-VLC state, used by `vlc:status` to render the NowPlaying bar.
let externalCtx = null   // { type: 'episode'|'movie', id, title, code, showName, showSlug }

let powerBlockerId = null
function startPowerBlocker() {
  if (powerBlockerId != null && powerSaveBlocker.isStarted(powerBlockerId)) return
  try { powerBlockerId = powerSaveBlocker.start('prevent-display-sleep') }
  catch (err) { console.warn('powerSaveBlocker start failed:', err.message) }
}
function stopPowerBlocker() {
  if (powerBlockerId == null) return
  try { if (powerSaveBlocker.isStarted(powerBlockerId)) powerSaveBlocker.stop(powerBlockerId) }
  catch {}
  powerBlockerId = null
}

function broadcast(channel, payload) {
  for (const win of BrowserWindow.getAllWindows()) {
    if (!win.isDestroyed()) win.webContents.send(channel, payload)
  }
}

function reshapeTracks(rawTracks) {
  return (rawTracks || []).filter(t => t.id !== -1).map(t => ({
    id: t.id,
    title: t.name || null,
    language: null,
    codec: null,
    channels: null,
  }))
}

function register(mainWindow) {
  // Lazily init libVLC the first time the renderer asks to start playback.
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

  // Forward libVLC pushes to renderer windows.
  vlcEmbed.events.on('state', s => broadcast('playback:state', s))
  vlcEmbed.events.on('tracks', t => broadcast('playback:tracks', {
    audio: reshapeTracks(t.audio),
    subtitle: reshapeTracks(t.subtitle),
  }))
  vlcEmbed.events.on('ended', e => broadcast('playback:ended', e))

  // ── Embedded libVLC ────────────────────────────────────────────────
  ipcMain.handle('vlc:embedStart', async (_e, url, opts = {}) => {
    try {
      if (!url) return { error: 'No stream URL' }
      await ensureInit()
      const startTime = opts.startTime || 0
      await vlcEmbed.start(url, startTime)
      startPowerBlocker()

      // Wait for the track list to settle (libVLC populates it async after open).
      let tracks = { audio: [], subtitle: [] }
      for (let i = 0; i < 30; i++) {
        await new Promise(r => setTimeout(r, 100))
        tracks = vlcEmbed.getTracks()
        const real = (tracks.audio || []).filter(t => t.id !== -1)
        if (real.length > 0) break
      }

      const state = vlcEmbed.getState()
      return {
        ok: true,
        duration: state.duration || 0,
        startTime,
        audioStreams: reshapeTracks(tracks.audio),
        subtitleStreams: reshapeTracks(tracks.subtitle),
      }
    } catch (err) {
      console.error('vlc:embedStart error:', err)
      return { error: err.message }
    }
  })

  ipcMain.handle('vlc:embedStop', async () => {
    try { await vlcEmbed.stop() } catch {}
    stopPowerBlocker()
    return { ok: true }
  })

  ipcMain.handle('vlc:embedSeek', async (_e, seconds) => {
    try { await vlcEmbed.seek(Number(seconds) || 0); return { ok: true } }
    catch (err) { return { error: err.message } }
  })
  ipcMain.handle('vlc:embedPause', async () => {
    try { await vlcEmbed.pause(); return { ok: true } } catch (err) { return { error: err.message } }
  })
  ipcMain.handle('vlc:embedResume', async () => {
    try { await vlcEmbed.resume(); return { ok: true } } catch (err) { return { error: err.message } }
  })
  ipcMain.handle('vlc:embedSwitchAudio', async (_e, id) => {
    try { vlcEmbed.setAudioTrack(id); return { ok: true } }
    catch (err) { return { error: err.message } }
  })
  ipcMain.handle('vlc:embedSwitchSubtitle', async (_e, id) => {
    try {
      const trackId = (id == null || id < 0) ? -1 : id
      vlcEmbed.setSubtitleTrack(trackId)
      return { ok: true }
    } catch (err) { return { error: err.message } }
  })

  // ── External VLC ───────────────────────────────────────────────────
  ipcMain.handle('vlc:checkInstalled', () => libvlc.isInstalled())

  ipcMain.handle('vlc:openInVlc', async (_e, payload = {}) => {
    const { url, episodeId, movieId, title, code, showName, showSlug, startTime } = payload
    if (!libvlc.isInstalled()) {
      return { error: 'VLC is not installed. Install it from https://www.videolan.org/' }
    }
    if (!url) return { error: 'No stream URL provided' }

    libvlc.stopPolling()
    externalCtx = episodeId
      ? { type: 'episode', id: episodeId, title, code, showName, showSlug }
      : movieId
      ? { type: 'movie', id: movieId, title }
      : null

    try {
      await libvlc.play(url, startTime || 0)
      setTimeout(() => libvlc.startPolling(), 2000)
      return { ok: true }
    } catch (err) { return { error: err.message } }
  })

  ipcMain.handle('vlc:openInDefault', async (_e, payload = {}) => {
    const { url } = payload
    if (!url) return { error: 'No stream URL provided' }
    try { await shell.openExternal(url); return { ok: true } }
    catch (err) { return { error: err.message } }
  })

  // External-VLC status, polled by NowPlaying when no in-app player is open.
  ipcMain.handle('vlc:status', () => {
    const tick = libvlc.lastTick()
    if (!tick) return { playing: false }
    const time = tick.time, duration = tick.length
    if (externalCtx?.type === 'episode') {
      return {
        playing: true, source: 'vlc', type: 'episode',
        episode_id: externalCtx.id, episode_title: externalCtx.title, episode_code: externalCtx.code,
        show_name: externalCtx.showName, show_slug: externalCtx.showSlug, time, duration,
      }
    }
    if (externalCtx?.type === 'movie') {
      return {
        playing: true, source: 'vlc', type: 'movie',
        movie_id: externalCtx.id, movie_title: externalCtx.title, time, duration,
      }
    }
    return { playing: true, source: 'vlc', time, duration }
  })

  // External VLC library control (used by NowPlaying scrubber).
  ipcMain.handle('vlc:libStatus', async () => { try { return await libvlc.status() } catch { return null } })
  ipcMain.handle('vlc:libPause',  async () => { try { await libvlc.pause();  return { ok: true } } catch (err) { return { error: err.message } } })
  ipcMain.handle('vlc:libResume', async () => { try { await libvlc.resume(); return { ok: true } } catch (err) { return { error: err.message } } })
  ipcMain.handle('vlc:libStop',   async () => {
    try { await libvlc.stop(); libvlc.stopPolling(); externalCtx = null; return { ok: true } }
    catch (err) { return { error: err.message } }
  })
  ipcMain.handle('vlc:libSeek',   async (_e, seconds) => { try { await libvlc.seek(seconds); return { ok: true } } catch (err) { return { error: err.message } } })
  ipcMain.handle('vlc:libVolume', async (_e, level) => { try { await libvlc.setVolume(level); return { ok: true } } catch (err) { return { error: err.message } } })
}

// External-VLC ended → tell renderer so the NowPlaying bar clears.
libvlc.events.on('ended', () => {
  externalCtx = null
  for (const win of BrowserWindow.getAllWindows()) {
    if (!win.isDestroyed()) win.webContents.send('vlc-playback-ended')
  }
})

module.exports = { register }
