// IPC handlers for the user's installed VLC.app — the "Open in VLC"
// feature and the NowPlaying scrubber that controls an external VLC
// subprocess over its HTTP interface.
//
// The in-app playback engine lives in ui/components/VideoPlayer.jsx
// (Jellyfin Player JS). The external VLC code path is kept because
// some users prefer to watch in a separate window with VLC's full UI,
// and because Caramba's NowPlaying bar surfaces playback progress when
// VLC is the active player.
const { ipcMain, shell, BrowserWindow } = require('electron')
const libvlc = require('../services/libvlc-player')

// External-VLC state, used by `vlc:status` to render the NowPlaying bar.
let externalCtx = null

function register(_mainWindow) {
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

  // Polled by NowPlaying when no in-app player is open.
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
