// VLC playback control via HTTP interface on localhost:9090.
// Reuses running VLC instance; spawns new one if not running.

const { spawn } = require('child_process')
const path = require('path')
const fs = require('fs')
const crypto = require('crypto')

const VLC_PATH = process.env.VLC_PATH || '/Applications/VLC.app/Contents/MacOS/VLC'
const VLC_HTTP_PORT = parseInt(process.env.VLC_HTTP_PORT || '9090', 10)
// Generate a random password per app session to prevent local cross-app access
const VLC_HTTP_PASSWORD = process.env.VLC_HTTP_PASSWORD || crypto.randomBytes(16).toString('hex')

const AUTH_HEADER = 'Basic ' + Buffer.from(`:${VLC_HTTP_PASSWORD}`).toString('base64')

async function vlcRequest(queryPath = '') {
  const url = `http://127.0.0.1:${VLC_HTTP_PORT}/requests/status.json${queryPath}`
  try {
    const res = await fetch(url, {
      headers: { Authorization: AUTH_HEADER },
      signal: AbortSignal.timeout(3000),
    })
    if (!res.ok) return null
    return await res.json()
  } catch {
    return null
  }
}

async function status() {
  const data = await vlcRequest()
  if (!data) return null
  return {
    state: data.state,
    time: parseInt(data.time) || 0,
    length: parseInt(data.length) || 0,
    position: parseFloat(data.position) || 0,
  }
}

async function isRunning() {
  const s = await status()
  return s != null
}

async function isActive() {
  const s = await status()
  return s != null && (s.state === 'playing' || s.state === 'paused')
}

function launchVlc(filePath, startTime) {
  if (!fs.existsSync(VLC_PATH)) {
    console.warn(`VlcPlayer: VLC not found at ${VLC_PATH}`)
    return null
  }

  const args = [
    filePath,
    '--extraintf', 'http',
    '--http-host', '127.0.0.1',
    '--http-port', String(VLC_HTTP_PORT),
    '--http-password', VLC_HTTP_PASSWORD,
    '--no-http-forward-cookies',
  ]

  if (startTime && parseInt(startTime) > 0) {
    args.push('--start-time', String(parseInt(startTime)))
  }

  const child = spawn(VLC_PATH, args, {
    detached: true,
    stdio: 'ignore',
  })
  child.unref()
  console.log(`VlcPlayer: launched VLC (PID=${child.pid}) for ${path.basename(filePath)}`)
  return child.pid
}

async function enqueueAndPlay(filePath, startTime) {
  // Build a proper file:// URI — encode each path component individually
  // to correctly handle spaces, #, ?, and other special characters in filenames
  const fileUri = 'file://' + filePath.split('/').map(c => encodeURIComponent(c)).join('/')

  await vlcRequest('?command=pl_empty')
  await vlcRequest(`?command=in_play&input=${fileUri}`)

  if (startTime && parseInt(startTime) > 0) {
    await new Promise(r => setTimeout(r, 500))
    await vlcRequest(`?command=seek&val=${parseInt(startTime)}`)
  }

  console.log(`VlcPlayer: sent ${path.basename(filePath)} to running VLC instance`)
  return true
}

async function play(filePath, startTime = 0) {
  if (await isRunning()) {
    return enqueueAndPlay(filePath, startTime)
  }
  return launchVlc(filePath, startTime)
}

async function stop() {
  try {
    await vlcRequest('?command=pl_stop')
  } catch { /* ignore */ }
}

module.exports = { play, stop, status, isRunning, isActive }
