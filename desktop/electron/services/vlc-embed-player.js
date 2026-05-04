// In-process libVLC player. Loads the native binding from
// electron/native/vlc-embed/, points it at the BrowserWindow's content
// NSView via getNativeWindowHandle(), and drives playback / track control
// through libvlc's C API.
//
// This service is the in-app playback engine — sibling of libvlc-player.js
// (which still spawns external VLC for the "Open in VLC" feature). The
// renderer never touches libvlc directly.
//
// Owns: process-lifetime libvlc instance, current media_player, the
// timer that polls libvlc for time/duration/state and emits 'state' /
// 'tracks' / 'ended' events.

const { EventEmitter } = require('events')
const fs = require('fs')
const path = require('path')

const ARCH = process.arch === 'x64' ? 'x64' : 'arm64'

function resolveNativeModule() {
  // Packaged: asarUnpacked .node lives at app.asar.unpacked/electron/native/...
  // Dev: source tree path
  const candidates = []
  if (process.resourcesPath) {
    candidates.push(path.join(
      process.resourcesPath, 'app.asar.unpacked',
      'electron', 'native', 'vlc-embed', 'build', 'Release', 'vlc_embed.node'
    ))
  }
  candidates.push(path.join(__dirname, '..', 'native', 'vlc-embed', 'build', 'Release', 'vlc_embed.node'))
  for (const p of candidates) {
    if (fs.existsSync(p)) return p
  }
  throw new Error(
    'vlc_embed.node not found. Run desktop/bin/setup-vlc to build it. ' +
    'Looked at: ' + candidates.join(' ; ')
  )
}

function resolvePluginPath() {
  // Packaged: extraResources mounts vendor/vlc-${arch}/plugins at Resources/vlc/plugins.
  // Dev: source tree.
  const candidates = []
  if (process.resourcesPath) {
    candidates.push(path.join(process.resourcesPath, 'vlc', 'plugins'))
  }
  candidates.push(path.join(__dirname, '..', '..', 'vendor', `vlc-${ARCH}`, 'plugins'))
  for (const p of candidates) {
    if (fs.existsSync(p)) return p
  }
  throw new Error('VLC plugin directory not found. Looked at: ' + candidates.join(' ; '))
}

const events = new EventEmitter()

let native = null
let nsViewBuffer = null
let pollTimer = null
let lastState = { time: 0, duration: 0, paused: false, playing: false, ended: false }
let lastTrackKey = ''

function isAvailable() {
  try { resolveNativeModule(); resolvePluginPath(); return true } catch { return false }
}

// One-time init. Pass the BrowserWindow's content NSView (Buffer from
// mainWindow.getNativeWindowHandle()). Also stashes the buffer for use
// by play() and sendBehind().
function init(nsViewHandle) {
  if (!nsViewHandle || !Buffer.isBuffer(nsViewHandle)) {
    throw new Error('init() requires a BrowserWindow native handle Buffer')
  }
  native = require(resolveNativeModule())
  nsViewBuffer = nsViewHandle
  native.vlcInit(resolvePluginPath(), nsViewHandle)
  native.vlcSetView(nsViewHandle)
}

function ensureInited() {
  if (!native) throw new Error('vlc-embed-player not initialized; call init() with the main window NSView handle first')
}

function startPolling() {
  if (pollTimer) return
  pollTimer = setInterval(() => {
    if (!native) return
    const s = native.vlcGetState()
    const changed =
      s.time !== lastState.time ||
      s.paused !== lastState.paused ||
      s.playing !== lastState.playing ||
      s.duration !== lastState.duration ||
      s.ended !== lastState.ended
    lastState = s
    if (changed) events.emit('state', s)
    if (s.ended) {
      // Don't stop polling here — caller decides via stop() / next-episode.
      events.emit('ended', s)
    }
    // Track list polling: libvlc populates tracks asynchronously after a
    // file is opened. Only emit when the (audio,subtitle) shape changes.
    try {
      const t = native.vlcGetTracks()
      const key = JSON.stringify(t)
      if (key !== lastTrackKey) {
        lastTrackKey = key
        events.emit('tracks', t)
      }
    } catch {}
  }, 250)
}

function stopPolling() {
  if (pollTimer) { clearInterval(pollTimer); pollTimer = null }
}

async function start(filePath, startTime = 0) {
  ensureInited()
  if (!fs.existsSync(filePath)) throw new Error('File not found: ' + filePath)
  native.vlcPlay(filePath, { startTime: Number(startTime) || 0 })
  // libvlc lazily creates its NSView when the first frame is decoded, so
  // we keep nudging it under Chromium's WebContents subview until the
  // class-name match succeeds (return value 1 == reordered, -1 == already
  // at bottom, 0 == VLC view not present yet).
  let attempts = 0
  const nudge = () => {
    attempts++
    let r = 0
    try { r = native.vlcSendBehind(nsViewBuffer) } catch {}
    if (r !== 0) return    // either reordered (1) or already at bottom (-1)
    if (attempts < 30) setTimeout(nudge, 200)
    else console.warn('[vlc-embed] sendBehind never matched a VLC subview after 6s; subviews =', native.vlcDebugSubviews?.(nsViewBuffer))
  }
  setTimeout(nudge, 100)
  lastTrackKey = ''
  startPolling()
}

async function stop() {
  if (!native) return
  try { native.vlcStop() } catch {}
  stopPolling()
  events.emit('state', { time: 0, duration: 0, paused: false, playing: false, ended: false })
}

async function pause()        { if (native) native.vlcPause() }
async function resume()       { if (native) native.vlcResume() }
async function seek(seconds)  { if (native) native.vlcSeek(Number(seconds) || 0) }
function getState()           { return native ? native.vlcGetState() : lastState }
function getTracks()          { return native ? native.vlcGetTracks() : { audio: [], subtitle: [] } }
function setAudioTrack(id)    { if (native && id != null) native.vlcSetAudioTrack(id|0) }
function setSubtitleTrack(id) { if (native) native.vlcSetSubtitleTrack(id == null ? -1 : (id|0)) }

function isPlaying() {
  if (!native) return false
  const s = native.vlcGetState()
  return !!(s.playing && !s.ended)
}

module.exports = {
  isAvailable,
  init,
  start,
  stop,
  pause,
  resume,
  seek,
  getState,
  getTracks,
  setAudioTrack,
  setSubtitleTrack,
  isPlaying,
  events,
}
