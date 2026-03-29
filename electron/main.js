const { app, BrowserWindow, shell, protocol, net } = require('electron')
const path = require('path')
const { Readable } = require('stream')
const db = require('./db')
const dbSync = require('./services/db-sync')
const transcoder = require('./services/transcoder')

// Suppress stream errors from transcoder teardown — they are harmless
// (e.g. write-after-end from ffmpeg pipe during stop/restart)
process.on('uncaughtException', (err) => {
  if (err.code === 'ERR_STREAM_WRITE_AFTER_END' || err.code === 'ERR_STREAM_DESTROYED') {
    console.warn('Suppressed stream error:', err.message)
    return
  }
  console.error('Uncaught exception:', err)
})

// IPC modules
const seriesIpc = require('./ipc/series')
const episodesIpc = require('./ipc/episodes')
const moviesIpc = require('./ipc/movies')
const playbackIpc = require('./ipc/playback')
const historyIpc = require('./ipc/history')
const settingsIpc = require('./ipc/settings')
const dialogsIpc = require('./ipc/dialogs')
const discoverIpc = require('./ipc/discover')

// Subtitle cache: stores the RAW VTT with original timestamps.
// The subtitle:// protocol handler shifts timestamps by the current seek offset.
let rawSubtitleCache = null
function setSubtitleCache(vttContent) { rawSubtitleCache = vttContent }
function getSubtitleCache() { return rawSubtitleCache }

/**
 * Parse a VTT timestamp (HH:MM:SS.mmm or MM:SS.mmm) into seconds.
 */
function parseVttTime(str) {
  const parts = str.split(':')
  if (parts.length === 3) {
    return parseFloat(parts[0]) * 3600 + parseFloat(parts[1]) * 60 + parseFloat(parts[2])
  } else if (parts.length === 2) {
    return parseFloat(parts[0]) * 60 + parseFloat(parts[1])
  }
  return parseFloat(str) || 0
}

/**
 * Format seconds back to VTT timestamp HH:MM:SS.mmm
 */
function formatVttTime(seconds) {
  if (seconds < 0) seconds = 0
  const h = Math.floor(seconds / 3600)
  const m = Math.floor((seconds % 3600) / 60)
  const s = seconds % 60
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${s.toFixed(3).padStart(6, '0')}`
}

/**
 * Shift all VTT cue timestamps by subtracting an offset.
 * Drops cues that end before the offset (they'd be in the past).
 */
function shiftVtt(vtt, offset) {
  if (!offset || offset <= 0) return vtt

  // Match VTT timestamp lines: "00:01.234 --> 00:05.678" or "00:00:01.234 --> 00:00:05.678"
  const timeLineRe = /^(\d{1,2}:(?:\d{2}:)?\d{2}\.\d{3})\s*-->\s*(\d{1,2}:(?:\d{2}:)?\d{2}\.\d{3})(.*)/

  const lines = vtt.split('\n')
  const result = []
  let skipCue = false

  for (let i = 0; i < lines.length; i++) {
    const match = lines[i].match(timeLineRe)
    if (match) {
      const startTime = parseVttTime(match[1]) - offset
      const endTime = parseVttTime(match[2]) - offset

      // Drop cues that end before 0 (already past)
      if (endTime <= 0) {
        skipCue = true
        continue
      }

      skipCue = false
      result.push(`${formatVttTime(Math.max(0, startTime))} --> ${formatVttTime(endTime)}${match[3]}`)
    } else if (skipCue) {
      // Skip text lines belonging to a dropped cue
      // Empty line ends a cue block
      if (lines[i].trim() === '') {
        skipCue = false
        result.push('')
      }
    } else {
      result.push(lines[i])
    }
  }

  return result.join('\n')
}

let mainWindow = null

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1280,
    height: 860,
    minWidth: 800,
    minHeight: 600,
    titleBarStyle: 'hiddenInset',
    trafficLightPosition: { x: 16, y: 16 },
    backgroundColor: '#000000',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  })

  // Register IPC handlers (dialogs needs the window reference)
  seriesIpc.register()
  episodesIpc.register()
  moviesIpc.register()
  playbackIpc.register()
  historyIpc.register()
  settingsIpc.register()
  dialogsIpc.register(mainWindow)
  discoverIpc.register()

  // Load the React app
  if (process.env.VITE_DEV_URL) {
    mainWindow.loadURL(process.env.VITE_DEV_URL)
  } else if (app.isPackaged) {
    mainWindow.loadFile(path.join(__dirname, '..', 'dist-react', 'index.html'))
  } else {
    mainWindow.loadFile(path.join(__dirname, '..', 'dist-react', 'index.html'))
  }

  // Open external links in system browser
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (url.startsWith('http')) shell.openExternal(url)
    return { action: 'deny' }
  })

  mainWindow.on('closed', () => {
    mainWindow = null
  })
}

// Register custom protocol schemes before app is ready
protocol.registerSchemesAsPrivileged([
  {
    scheme: 'stream',
    privileges: { stream: true, supportFetchAPI: true, corsEnabled: true },
  },
  {
    scheme: 'subtitle',
    privileges: { supportFetchAPI: true, corsEnabled: true },
  },
])

app.whenReady().then(() => {
  // Register stream:// protocol — serves transcoded video from ffmpeg pipe
  protocol.handle('stream', () => {
    const transcoderStream = transcoder.getActiveStream()
    if (!transcoderStream) {
      return new Response('No active stream', { status: 404 })
    }

    // Convert Node.js PassThrough to a web ReadableStream
    const readable = Readable.toWeb(transcoderStream)

    return new Response(readable, {
      headers: {
        'Content-Type': 'video/mp4',
        'Cache-Control': 'no-cache',
      },
    })
  })

  // Register subtitle:// protocol — serves VTT with timestamps shifted by seek offset
  protocol.handle('subtitle', () => {
    if (!rawSubtitleCache) {
      return new Response('No subtitles', { status: 404 })
    }

    // Shift timestamps so cues align with video.currentTime (which starts at 0 after each seek)
    const seekBase = playbackIpc.getCurrentSeekBase()
    const shifted = shiftVtt(rawSubtitleCache, seekBase)

    return new Response(shifted, {
      headers: {
        'Content-Type': 'text/vtt; charset=utf-8',
        'Cache-Control': 'no-cache',
      },
    })
  })

  // Open database
  db.open()

  // Startup sync check (async, fire-and-forget — must not block app startup)
  dbSync.syncOnStartup().catch(err => console.warn('DbSync: startup sync error —', err.message))

  createWindow()

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})

app.on('window-all-closed', () => {
  transcoder.stop()
  app.quit()
})

let isQuitting = false
app.on('before-quit', (e) => {
  if (isQuitting) return // prevent infinite loop from app.quit() below
  isQuitting = true
  e.preventDefault()
  transcoder.stop()
  dbSync.dump()
    .catch(err => console.warn('DbSync: dump on quit failed —', err.message))
    .finally(() => {
      db.close()
      app.quit()
    })
})

module.exports = { setSubtitleCache, getSubtitleCache }
