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

let Sentry = null
try { Sentry = require('@sentry/electron/main') } catch {}

const ARCH = process.arch === 'x64' ? 'x64' : 'arm64'

function resolveNativeModule() {
  // Packaged: extraResources puts the .node at Resources/vlc-embed/...
  // Dev: source tree path.
  const candidates = []
  if (process.resourcesPath) {
    candidates.push(path.join(process.resourcesPath, 'vlc-embed', 'vlc_embed.node'))
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

// Stall-detection bookkeeping. We declare a stall when libvlc reports
// playing && !paused but the media-time hasn't advanced for STALL_DETECT_MS
// of wall-clock time. That definition is engine-agnostic — it catches I/O
// underruns, decoder hangs, and audio/video resync pauses alike. On stall
// start and recovery we emit a Sentry event with file/system context so we
// can correlate stalls to real causes (NAS path, memory pressure, etc.).
const STALL_DETECT_MS = 2500
let lastForwardWallclockMs = 0
let lastForwardMediaTime = 0
let stallActive = false
let stallStartedAtMs = 0
let stallStartMediaTime = 0
let mediaContext = null    // populated by start(), cleared by stop()

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
    detectStall(s)
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

function detectStall(s) {
  if (!mediaContext) return
  const now = Date.now()
  const playing = !!s.playing && !s.paused && !s.ended
  if (!playing) {
    // Pause / EOF resets the progress baseline so resuming doesn't
    // immediately fire a "stall" for the elapsed paused interval.
    lastForwardWallclockMs = now
    lastForwardMediaTime = s.time
    return
  }
  const advanced = s.time > lastForwardMediaTime + 0.1
  if (advanced) {
    if (stallActive) {
      const stallMs = now - stallStartedAtMs
      stallActive = false
      try {
        Sentry?.addBreadcrumb?.({
          category: 'vlc-embed',
          level: 'info',
          message: 'stall recovered',
          data: { stallMs, mediaTime: s.time, stallStartMediaTime },
        })
        Sentry?.captureMessage?.('vlc playback stall recovered', {
          level: 'info',
          tags: { subsystem: 'vlc-embed', kind: 'stall_recovered' },
          extra: {
            stallMs,
            mediaTime: s.time,
            stallStartMediaTime,
            ...mediaContext,
          },
        })
      } catch {}
    }
    lastForwardWallclockMs = now
    lastForwardMediaTime = s.time
    return
  }
  if (!stallActive && now - lastForwardWallclockMs > STALL_DETECT_MS) {
    stallActive = true
    stallStartedAtMs = now
    stallStartMediaTime = s.time
    let mem = null
    try { mem = process.memoryUsage() } catch {}
    try {
      Sentry?.captureMessage?.('vlc playback stall detected', {
        level: 'warning',
        tags: { subsystem: 'vlc-embed', kind: 'stall_detected' },
        extra: {
          wallSinceLastAdvanceMs: now - lastForwardWallclockMs,
          mediaTime: s.time,
          duration: s.duration,
          memoryRssMb: mem ? Math.round(mem.rss / 1024 / 1024) : null,
          memoryHeapUsedMb: mem ? Math.round(mem.heapUsed / 1024 / 1024) : null,
          ...mediaContext,
        },
      })
    } catch {}
  }
}

function describeMediaSource(filePath) {
  const ctx = {
    fileBasename: path.basename(filePath),
    fileSize: null,
    storage: 'unknown',
    mountPoint: null,
  }
  try {
    const st = fs.statSync(filePath)
    ctx.fileSize = st.size
  } catch {}
  // Anything under /Volumes is either a NAS share (SMB/AFP/NFS), an
  // external/USB disk, or a disk image. macOS doesn't surface the fs type
  // cheaply from JS; the mount point is enough to correlate stalls with
  // network-mounted media in Sentry. Local Documents/Movies/Downloads
  // resolve through the user's home dir, NOT /Volumes.
  if (filePath.startsWith('/Volumes/')) {
    const parts = filePath.split('/')
    ctx.storage = 'mounted'
    ctx.mountPoint = '/' + parts.slice(1, 3).join('/')
  } else {
    ctx.storage = 'local'
  }
  return ctx
}

function stopPolling() {
  if (pollTimer) { clearInterval(pollTimer); pollTimer = null }
}

async function start(filePath, startTime = 0) {
  ensureInited()
  if (!fs.existsSync(filePath)) throw new Error('File not found: ' + filePath)
  mediaContext = { ...describeMediaSource(filePath), startTime: Number(startTime) || 0 }
  lastForwardWallclockMs = Date.now()
  lastForwardMediaTime = Number(startTime) || 0
  stallActive = false
  try {
    Sentry?.addBreadcrumb?.({
      category: 'vlc-embed',
      level: 'info',
      message: 'playback started',
      data: { ...mediaContext },
    })
  } catch {}
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
  mediaContext = null
  stallActive = false
  events.emit('state', { time: 0, duration: 0, paused: false, playing: false, ended: false })
}

async function pause()        { if (native) native.vlcPause() }
async function resume()       { if (native) native.vlcResume() }
async function seek(seconds)  {
  if (!native) return
  // Reset the stall baseline — libvlc's time jumps to the seek target,
  // which would otherwise look like 2.5s of "no advance" and fire a
  // false-positive stall event.
  lastForwardWallclockMs = Date.now()
  lastForwardMediaTime = Number(seconds) || 0
  stallActive = false
  native.vlcSeek(Number(seconds) || 0)
}
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
