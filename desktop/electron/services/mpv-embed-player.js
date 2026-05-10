// In-process libmpv player. Loads the native binding from
// electron/native/mpv-embed/, points it at the BrowserWindow's content
// NSView via getNativeWindowHandle(), and drives playback / track
// control through libmpv's C API. The renderer never touches libmpv
// directly.
//
// Sibling: libvlc-player.js still owns the external VLC subprocess
// used for the "Open in VLC" feature.
//
// Owns: process-lifetime mpv instance, the timer that polls libmpv for
// time/duration/state, and the event emitter ('state' / 'tracks' /
// 'ended') consumed by the IPC layer.

const { EventEmitter } = require('events')
const fs = require('fs')
const path = require('path')

let Sentry = null
try { Sentry = require('@sentry/electron/main') } catch {}

const ARCH = process.arch === 'x64' ? 'x64' : 'arm64'

function resolveNativeModule() {
  // Packaged: extraResources puts the .node at Resources/mpv-embed/...
  // Dev: source tree path.
  const candidates = []
  if (process.resourcesPath) {
    candidates.push(path.join(process.resourcesPath, 'mpv-embed', 'mpv_embed.node'))
  }
  candidates.push(path.join(__dirname, '..', 'native', 'mpv-embed', 'build', 'Release', 'mpv_embed.node'))
  for (const p of candidates) {
    if (fs.existsSync(p)) return p
  }
  throw new Error(
    'mpv_embed.node not found. Run desktop/bin/setup-mpv to fetch libmpv and build it. ' +
    'Looked at: ' + candidates.join(' ; ')
  )
}

const events = new EventEmitter()

let native = null
let nsViewBuffer = null
let pollTimer = null
let lastState = { time: 0, duration: 0, paused: false, playing: false, ended: false }
let lastTrackKey = ''
let cachedCapabilities = null

// Stall-detection bookkeeping. We declare a stall when libmpv reports
// playing && !paused but media-time hasn't advanced for STALL_DETECT_MS
// of wall-clock time. Engine-agnostic definition — catches I/O
// underruns, decoder hangs, and audio/video resync pauses alike.
const STALL_DETECT_MS = 2500
let lastForwardWallclockMs = 0
let lastForwardMediaTime = 0
let stallActive = false
let stallStartedAtMs = 0
let stallStartMediaTime = 0
let mediaContext = null    // populated by start(), cleared by stop()

function isAvailable() {
  try { resolveNativeModule(); return true } catch { return false }
}

// One-time init. Pass the BrowserWindow's content NSView (Buffer from
// mainWindow.getNativeWindowHandle()). Also stashes the buffer for
// later sendBehind() / subview-frame calls.
function init(nsViewHandle) {
  if (!nsViewHandle || !Buffer.isBuffer(nsViewHandle)) {
    throw new Error('init() requires a BrowserWindow native handle Buffer')
  }
  native = require(resolveNativeModule())
  nsViewBuffer = nsViewHandle
  native.mpvInit(nsViewHandle)
}

function ensureInited() {
  if (!native) throw new Error('mpv-embed-player not initialized; call init() with the main window NSView handle first')
}

function startPolling() {
  if (pollTimer) return
  pollTimer = setInterval(() => {
    if (!native) return
    const s = native.mpvGetState()
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
      events.emit('ended', s)
    }
    // Track list polling: libmpv populates tracks on FILE_LOADED. Only
    // emit when the shape changes so we don't spam consumers.
    try {
      const t = native.mpvGetTracks()
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
          category: 'mpv-embed',
          level: 'info',
          message: 'stall recovered',
          data: { stallMs, mediaTime: s.time, stallStartMediaTime },
        })
        Sentry?.captureMessage?.('mpv playback stall recovered', {
          level: 'info',
          tags: { subsystem: 'mpv-embed', kind: 'stall_recovered' },
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
      Sentry?.captureMessage?.('mpv playback stall detected', {
        level: 'warning',
        tags: { subsystem: 'mpv-embed', kind: 'stall_detected' },
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

// describeMediaSource: classify an HTTP URL by host for Sentry breadcrumbs.
// The desktop is a pure client now — playback URLs come from the Rails
// server (/api/playback/file/... or /api/playback/hls/...).
function describeMediaSource(url) {
  const ctx = { url, storage: 'http' }
  try {
    const u = new URL(url)
    ctx.host = u.host
    ctx.protocol = u.protocol
  } catch {}
  return ctx
}

function stopPolling() {
  if (pollTimer) { clearInterval(pollTimer); pollTimer = null }
}

async function start(urlOrPath, startTime = 0) {
  ensureInited()
  mediaContext = { ...describeMediaSource(urlOrPath), startTime: Number(startTime) || 0 }
  lastForwardWallclockMs = Date.now()
  lastForwardMediaTime = Number(startTime) || 0
  stallActive = false
  try {
    Sentry?.addBreadcrumb?.({
      category: 'mpv-embed',
      level: 'info',
      message: 'playback started',
      data: { ...mediaContext },
    })
  } catch {}
  native.mpvPlay(urlOrPath, { startTime: Number(startTime) || 0 })
  // libmpv attaches its vout subview asynchronously after the file
  // demuxer opens. Nudge it under Chromium's WebContents subview until
  // the class-match succeeds.
  let attempts = 0
  const nudge = () => {
    attempts++
    let r = 0
    try { r = native.mpvSendBehind(nsViewBuffer) } catch {}
    if (r !== 0) return    // either reordered (1) or already at bottom (-1)
    if (attempts < 30) setTimeout(nudge, 200)
    else console.warn('[mpv-embed] sendBehind never matched an mpv subview after 6s; subviews =', native.mpvDebugSubviews?.(nsViewBuffer))
  }
  setTimeout(nudge, 100)
  lastTrackKey = ''
  startPolling()
}

async function stop() {
  if (!native) return
  try { native.mpvStop() } catch {}
  stopPolling()
  mediaContext = null
  stallActive = false
  events.emit('state', { time: 0, duration: 0, paused: false, playing: false, ended: false })
}

async function pause()       { if (native) native.mpvPause() }
async function resume()      { if (native) native.mpvResume() }
async function seek(seconds) {
  if (!native) return
  // Reset the stall baseline — mpv's time jumps to the seek target,
  // which would otherwise look like 2.5s of "no advance".
  lastForwardWallclockMs = Date.now()
  lastForwardMediaTime = Number(seconds) || 0
  stallActive = false
  native.mpvSeek(Number(seconds) || 0)
}
function getState()           { return native ? native.mpvGetState()  : lastState }
function getTracks()          { return native ? native.mpvGetTracks() : { audio: [], subtitle: [] } }
function setAudioTrack(id)    { if (native && id != null) native.mpvSetAudioTrack(id|0) }
function setSubtitleTrack(id) { if (native) native.mpvSetSubtitleTrack(id == null ? -1 : (id|0)) }

function isPlaying() {
  if (!native) return false
  const s = native.mpvGetState()
  return !!(s.playing && !s.ended)
}

// Decoder / demuxer enumeration for the DeviceProfile builder. Cached
// after the first call — these don't change at runtime.
function getCapabilities() {
  if (cachedCapabilities) return cachedCapabilities
  if (!native) return { decoders: [], demuxers: [] }
  cachedCapabilities = native.mpvGetCapabilities()
  return cachedCapabilities
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
  getCapabilities,
  events,
}
