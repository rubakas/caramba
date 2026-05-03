// libvlc-player: thin library wrapper around VLC for the desktop app.
//
// Card #60 (alternative to libmpv in #54). The native libVLC C bindings would
// embed playback into an Electron canvas, but webchimera.js / @videolan/libvlc
// don't compile against current Electron. Until those bindings catch up we use
// node-vlc-http, the third option the card lists, against an external VLC
// process — same control surface the renderer would use against true libVLC,
// so the IPC and adapter shape is what would survive a future swap.
//
// Owns: VLC process spawn, HTTP control client, playback session state.

const { spawn } = require('child_process')
const { EventEmitter } = require('events')
const fs = require('fs')
const path = require('path')
const crypto = require('crypto')
const { VLC } = require('node-vlc-http')

const DEFAULT_VLC_PATH = process.env.VLC_PATH || '/Applications/VLC.app/Contents/MacOS/VLC'
const DEFAULT_VLC_APP_PATH = '/Applications/VLC.app'
const VLC_HTTP_HOST = '127.0.0.1'
const VLC_HTTP_PORT = parseInt(process.env.VLC_HTTP_PORT || '9090', 10)
// Random per-app-session password: prevents other local processes from driving
// our VLC instance over the loopback HTTP interface.
const VLC_HTTP_PASSWORD = process.env.VLC_HTTP_PASSWORD || crypto.randomBytes(16).toString('hex')

const POLL_INTERVAL_MS = 3000

const events = new EventEmitter()
let client = null
let pollTimer = null
let lastStatus = null
let connectingPromise = null

function isInstalled() {
  return fs.existsSync(DEFAULT_VLC_APP_PATH) || fs.existsSync(DEFAULT_VLC_PATH)
}

function fileUriFor(filePath) {
  return 'file://' + filePath.split('/').map(c => encodeURIComponent(c)).join('/')
}

function spawnIfNeeded(filePath, startTime) {
  if (!fs.existsSync(DEFAULT_VLC_PATH)) {
    throw new Error(`VLC binary not found at ${DEFAULT_VLC_PATH}`)
  }
  const args = [
    filePath,
    '--extraintf', 'http',
    '--http-host', VLC_HTTP_HOST,
    '--http-port', String(VLC_HTTP_PORT),
    '--http-password', VLC_HTTP_PASSWORD,
    '--no-http-forward-cookies',
  ]
  if (startTime && parseInt(startTime, 10) > 0) {
    args.push('--start-time', String(parseInt(startTime, 10)))
  }
  const child = spawn(DEFAULT_VLC_PATH, args, { detached: true, stdio: 'ignore' })
  child.unref()
  return child.pid
}

// Open a control client. `autoUpdate: false` disables the 30fps tick — we poll
// at our own rate from outside. `maxTries: 1` means the constructor's connect
// probe fails fast if VLC isn't up yet, leaving callers to retry.
async function ensureClient() {
  if (client) return client
  if (connectingPromise) return connectingPromise

  connectingPromise = new Promise((resolve, reject) => {
    const c = new VLC({
      host: VLC_HTTP_HOST,
      port: VLC_HTTP_PORT,
      username: '',
      password: VLC_HTTP_PASSWORD,
      autoUpdate: false,
      changeEvents: false,
      maxTries: 1,
    })
    let settled = false
    c.once('connect', () => {
      if (settled) return
      settled = true
      client = c
      resolve(c)
    })
    c.once('error', err => {
      if (settled) return
      settled = true
      reject(err)
    })
  }).finally(() => {
    connectingPromise = null
  })

  return connectingPromise
}

async function probeRunning() {
  try {
    const c = await ensureClient()
    return await c.updateStatus()
  } catch {
    client = null
    return null
  }
}

async function play(filePath, startTime = 0) {
  const uri = fileUriFor(filePath)
  let status = await probeRunning()

  if (!status) {
    spawnIfNeeded(filePath, startTime)
    // Give VLC's HTTP interface a moment to come up before we try to connect.
    for (let i = 0; i < 20; i++) {
      await new Promise(r => setTimeout(r, 250))
      status = await probeRunning()
      if (status) break
    }
    if (!status) throw new Error('VLC HTTP interface did not become reachable')
    return { spawned: true, file: path.basename(filePath) }
  }

  const c = await ensureClient()
  await c.playlistEmpty()
  await c.addToQueueAndPlay(uri)
  if (startTime && parseInt(startTime, 10) > 0) {
    await new Promise(r => setTimeout(r, 500))
    await c.seek(parseInt(startTime, 10))
  }
  return { spawned: false, file: path.basename(filePath) }
}

async function pause() {
  const c = await ensureClient()
  return c.forcePause()
}

async function resume() {
  const c = await ensureClient()
  return c.resume()
}

async function stop() {
  if (!client) return null
  try { return await client.stop() } catch { return null }
}

async function seek(seconds) {
  const c = await ensureClient()
  return c.seek(parseInt(seconds, 10))
}

async function setVolume(level) {
  const c = await ensureClient()
  return c.setVolume(level)
}

async function status() {
  const s = await probeRunning()
  if (!s) return null
  return {
    state: s.state,
    time: parseInt(s.time, 10) || 0,
    length: parseInt(s.length, 10) || 0,
    position: parseFloat(s.position) || 0,
    volume: parseInt(s.volume, 10) || 0,
    rate: parseFloat(s.rate) || 1,
  }
}

async function isRunning() {
  const s = await probeRunning()
  return s != null
}

async function isActive() {
  const s = await probeRunning()
  return s != null && (s.state === 'playing' || s.state === 'paused')
}

// Polling layer: emits 'tick' (with status) and 'ended' when VLC stops.
// Callers (playback IPC) subscribe instead of running their own setInterval.
function startPolling() {
  if (pollTimer) return
  pollTimer = setInterval(async () => {
    const data = await probeRunning()
    if (!data || data.state === 'stopped') {
      const final = lastStatus
      lastStatus = null
      stopPolling()
      events.emit('ended', final)
      return
    }
    lastStatus = {
      state: data.state,
      time: parseInt(data.time, 10) || 0,
      length: parseInt(data.length, 10) || 0,
    }
    events.emit('tick', lastStatus)
  }, POLL_INTERVAL_MS)
}

function stopPolling() {
  if (pollTimer) {
    clearInterval(pollTimer)
    pollTimer = null
  }
}

function lastTick() {
  return lastStatus
}

module.exports = {
  isInstalled,
  play,
  pause,
  resume,
  stop,
  seek,
  setVolume,
  status,
  isRunning,
  isActive,
  startPolling,
  stopPolling,
  lastTick,
  events,
  appPath: DEFAULT_VLC_APP_PATH,
  binaryPath: DEFAULT_VLC_PATH,
}
