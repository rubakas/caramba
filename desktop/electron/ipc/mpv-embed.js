// IPC handlers for the in-process libmpv playback engine.
//
// The native module (electron/native/mpv-embed) drives libmpv directly
// inside the Electron main process, embedding video as a subview of the
// BrowserWindow's NSView. The renderer talks to mpv only through these
// IPC channels — never through window.* directly.
//
// This file owns:
//   * One-time mpv init bound to the BrowserWindow's native handle.
//   * Lifecycle (start/stop/seek/pause/resume) for the active session.
//   * Audio/subtitle track switching.
//   * Power-save blocker that prevents display sleep during playback.
//   * Forwarding mpv's state/tracks/ended events to all renderer windows.
//
// External VLC ("Open in VLC" subprocess + library control) lives in
// ipc/vlc.js — separate concerns, separate file.
const { ipcMain, BrowserWindow, powerSaveBlocker } = require('electron')
const mpvEmbed = require('../services/mpv-embed-player')

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
    title: t.title || null,
    language: t.language || null,
    codec: t.codec || null,
    channels: t.channels || null,
  }))
}

function register(mainWindow) {
  let initPromise = null
  function ensureInit() {
    if (initPromise) return initPromise
    initPromise = (async () => {
      if (!mpvEmbed.isAvailable()) {
        throw new Error('libmpv embed not available — run desktop/bin/setup-mpv')
      }
      mpvEmbed.init(mainWindow.getNativeWindowHandle())
    })()
    return initPromise
  }

  // Forward mpv pushes to renderer windows.
  mpvEmbed.events.on('state',  s => broadcast('playback:state', s))
  mpvEmbed.events.on('tracks', t => broadcast('playback:tracks', {
    audio: reshapeTracks(t.audio),
    subtitle: reshapeTracks(t.subtitle),
  }))
  mpvEmbed.events.on('ended',  e => broadcast('playback:ended', e))

  ipcMain.handle('mpv:embedStart', async (_e, url, opts = {}) => {
    try {
      if (!url) return { error: 'No stream URL' }
      await ensureInit()
      const startTime = opts.startTime || 0
      // Race: native FILE_LOADED event (resolves with the freshly
      // populated tracks) vs. a 15s timeout. The previous "poll for
      // tracks" approach silently returned ok:true with empty tracks
      // when mpv never actually loaded, masking real bugs. Now we
      // return a hard error on timeout and let the adapter fall back.
      const fileLoadedPromise = new Promise((resolve) => {
        const onState = () => {} // ignored; we wait specifically for tracks
        const onTracks = (tracks) => {
          mpvEmbed.events.off('tracks', onTracks)
          resolve({ kind: 'loaded', tracks })
        }
        mpvEmbed.events.once('tracks', onTracks)
        // Bail-out if mpv ends with an error before FILE_LOADED fires.
        const onEnded = (s) => {
          mpvEmbed.events.off('tracks', onTracks)
          resolve({ kind: 'ended', reason: s })
        }
        mpvEmbed.events.once('ended', onEnded)
      })

      await mpvEmbed.start(url, startTime)
      startPowerBlocker()

      const FILE_LOADED_TIMEOUT_MS = 15_000
      const outcome = await Promise.race([
        fileLoadedPromise,
        new Promise(r => setTimeout(() => r({ kind: 'timeout' }), FILE_LOADED_TIMEOUT_MS)),
      ])

      if (outcome.kind === 'timeout' || outcome.kind === 'ended') {
        // libmpv didn't reach FILE_LOADED. Stop the engine so it
        // doesn't keep a half-open stream while we fall back.
        try { await mpvEmbed.stop() } catch {}
        stopPowerBlocker()
        const why = outcome.kind === 'timeout'
          ? `FILE_LOADED never fired within ${FILE_LOADED_TIMEOUT_MS}ms`
          : `playback ended before FILE_LOADED (${outcome.reason?.ended ? 'eof' : 'aborted'})`
        return { error: `libmpv start failed: ${why}` }
      }

      const tracks = outcome.tracks || { audio: [], subtitle: [] }
      const state = mpvEmbed.getState()
      return {
        ok: true,
        duration: state.duration || 0,
        startTime,
        audioStreams: reshapeTracks(tracks.audio),
        subtitleStreams: reshapeTracks(tracks.subtitle),
      }
    } catch (err) {
      console.error('mpv:embedStart error:', err)
      return { error: err.message }
    }
  })

  ipcMain.handle('mpv:embedStop', async () => {
    try { await mpvEmbed.stop() } catch {}
    stopPowerBlocker()
    return { ok: true }
  })

  ipcMain.handle('mpv:embedSeek', async (_e, seconds) => {
    try { await mpvEmbed.seek(Number(seconds) || 0); return { ok: true } }
    catch (err) { return { error: err.message } }
  })
  ipcMain.handle('mpv:embedPause', async () => {
    try { await mpvEmbed.pause(); return { ok: true } } catch (err) { return { error: err.message } }
  })
  ipcMain.handle('mpv:embedResume', async () => {
    try { await mpvEmbed.resume(); return { ok: true } } catch (err) { return { error: err.message } }
  })
  ipcMain.handle('mpv:embedSwitchAudio', async (_e, id) => {
    try { mpvEmbed.setAudioTrack(id); return { ok: true } }
    catch (err) { return { error: err.message } }
  })
  ipcMain.handle('mpv:embedSwitchSubtitle', async (_e, id) => {
    try {
      const trackId = (id == null || id < 0) ? -1 : id
      mpvEmbed.setSubtitleTrack(trackId)
      return { ok: true }
    } catch (err) { return { error: err.message } }
  })

  // Capabilities for the device profile builder. Returns the codec /
  // demuxer / subtitle lists libmpv can decode on this build, queried at
  // first call and cached.
  ipcMain.handle('mpv:capabilities', async () => {
    try {
      await ensureInit()
      return mpvEmbed.getCapabilities()
    } catch (err) {
      return { error: err.message }
    }
  })
}

module.exports = { register }
