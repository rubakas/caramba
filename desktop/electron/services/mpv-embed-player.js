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

// Composite state derived from individual mpv property pushes. Updated
// from the native event callback below; emitted as 'state' on change.
const compState = {
  time: 0,
  duration: 0,
  paused: false,        // mpv "pause" property
  coreIdle: true,       // mpv "core-idle" — true when nothing's playing
  pausedForCache: false,
  eofReached: false,
  idleActive: true,
  ended: false,
}

// Translates the compState into the public {time, duration, paused,
// playing, ended} shape that the rest of the app expects.
//
// `playing` semantics: the file has loaded (duration > 0) and the
// player isn't paused / at EOF. We deliberately don't gate on
// `core-idle` — mpv reports core-idle=true while waiting for the VO to
// produce a frame even when decode is healthy (audio is flowing,
// time-pos advancing). Gating on core-idle leaves `playing` stuck at
// false during the brief window between FILE_LOADED and first video
// frame, blocking PlayerContext from flipping engineReady.
function projectState() {
  const playing = compState.duration > 0 && !compState.paused && !compState.eofReached
  return {
    time: compState.time,
    duration: compState.duration,
    paused: compState.paused,
    playing,
    ended: compState.eofReached,
  }
}

let prevProjection = projectState()

function emitStateIfChanged() {
  const s = projectState()
  if (s.time === prevProjection.time &&
      s.duration === prevProjection.duration &&
      s.paused === prevProjection.paused &&
      s.playing === prevProjection.playing &&
      s.ended === prevProjection.ended) {
    return
  }
  prevProjection = s
  lastState = s
  events.emit('state', s)
  detectStall(s)
  // NB: do NOT emit 'ended' on a state change. mpv's `eof-reached`
  // property flickers true during seeks and brief decoder hiccups —
  // emitting 'ended' on that prematurely closes the player session.
  // The authoritative end-of-file signal is MPV_EVENT_END_FILE with
  // reason=EOF, dispatched separately in the 'endFile' case of
  // onNativeEvent.
}

function emitTracksIfChanged() {
  if (!native) return
  try {
    const t = native.mpvGetTracks()
    const key = JSON.stringify(t)
    if (key !== lastTrackKey) {
      lastTrackKey = key
      events.emit('tracks', t)
    }
  } catch {}
}

// Native event dispatcher. Called on the JS main thread via Napi's
// ThreadSafeFunction from the pump thread in binding.mm.
function onNativeEvent(ev) {
  if (!ev || !ev.type) return
  switch (ev.type) {
    case 'property': {
      switch (ev.name) {
        case 'time-pos':        if (typeof ev.value === 'number') compState.time = ev.value; break
        case 'duration':        if (typeof ev.value === 'number') compState.duration = ev.value; break
        case 'pause':           compState.paused = !!ev.value; break
        case 'core-idle':       compState.coreIdle = !!ev.value; break
        case 'paused-for-cache':compState.pausedForCache = !!ev.value; break
        case 'eof-reached':     compState.eofReached = !!ev.value; break
        case 'idle-active':     compState.idleActive = !!ev.value; break
      }
      emitStateIfChanged()
      break
    }
    case 'fileLoaded': {
      // Track list is populated by now. Emit tracks once, then unpause
      // — playback was deferred via pause=yes in MpvPlay so we could
      // gate frame delivery on the demuxer being fully open. Mirrors
      // JMP's ApplyPendingTrackSelectionAndPlay (handle.h:197-216).
      emitTracksIfChanged()
      try { native.mpvResume() } catch {}
      break
    }
    case 'endFile': {
      // ev.value is the reason string (eof / stop / quit / error / redirect).
      // Only EOF means "the file naturally finished" — STOP/QUIT mean the
      // host explicitly tore the session down (no auto-advance please);
      // ERROR / REDIRECT are transitional. Emit 'ended' only for EOF.
      const reason = ev.value || ev.text || ''
      compState.eofReached = reason === 'eof'
      compState.idleActive = true
      emitStateIfChanged()
      if (reason === 'eof') {
        events.emit('ended', projectState())
      } else if (reason.startsWith('error:')) {
        console.warn('[mpv-embed] end-file error:', reason)
      }
      break
    }
    case 'log': {
      // Forward mpv's own logs to the Electron main console. Only
      // surface info+ to avoid noise; the binding requested "info" level.
      const prefix = ev.name || 'mpv'
      const text = ev.value || ev.text || ''
      // Most of mpv's "info" lines are useful diagnostic context.
      console.log(`[mpv:${prefix}] ${text}`)
      break
    }
    case 'startFile': {
      // Reset per-file state so a stale `ended` flag doesn't leak.
      compState.eofReached = false
      compState.idleActive = false
      emitStateIfChanged()
      break
    }
    case 'shutdown': {
      // mpv terminated. Mostly fired during releaseMpv()'s teardown.
      break
    }
  }
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
  native.mpvInit(nsViewHandle, onNativeEvent)
}

function ensureInited() {
  if (!native) throw new Error('mpv-embed-player not initialized; call init() with the main window NSView handle first')
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

async function start(urlOrPath, startTime = 0) {
  ensureInited()
  mediaContext = { ...describeMediaSource(urlOrPath), startTime: Number(startTime) || 0 }
  lastForwardWallclockMs = Date.now()
  lastForwardMediaTime = Number(startTime) || 0
  stallActive = false
  // Reset projection so the next batch of property events triggers an
  // emit even if the new values happen to match the previous file's.
  compState.time = Number(startTime) || 0
  compState.duration = 0
  compState.paused = false
  compState.coreIdle = true
  compState.pausedForCache = false
  compState.eofReached = false
  compState.idleActive = true
  compState.ended = false
  prevProjection = projectState()
  lastTrackKey = ''
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
}

async function stop() {
  if (!native) return
  try { native.mpvStop() } catch {}
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
