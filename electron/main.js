const { app, BrowserWindow, shell, protocol, net, ipcMain } = require('electron')
const path = require('path')
const fs = require('fs')
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
const updaterIpc = require('./ipc/updater')
const downloadsIpc = require('./ipc/downloads')

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
  const windowOpts = {
    width: 1280,
    height: 860,
    minWidth: 800,
    minHeight: 600,
    backgroundColor: '#000000',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  }

  // macOS: hide title bar, show traffic lights inset
  if (process.platform === 'darwin') {
    windowOpts.titleBarStyle = 'hiddenInset'
    windowOpts.trafficLightPosition = { x: 16, y: 16 }
  }

  mainWindow = new BrowserWindow(windowOpts)

  // Register IPC handlers (dialogs needs the window reference)
  seriesIpc.register()
  episodesIpc.register()
  moviesIpc.register()
  playbackIpc.register()
  historyIpc.register()
  settingsIpc.register()
  dialogsIpc.register(mainWindow)
  discoverIpc.register()
  updaterIpc.register(mainWindow)
  downloadsIpc.register()

  // Dev-only: save glass config to src/config/glass.json for playground persistence
  if (!app.isPackaged) {
    ipcMain.handle('dev:saveGlassConfig', async (_event, config) => {
      const configPath = path.join(__dirname, '..', 'src', 'config', 'glass.json')
      fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + '\n', 'utf-8')
      return { ok: true }
    })
  }

  // Load the React app
  // Security: only allow VITE_DEV_URL in development builds to prevent
  // env-var poisoning from redirecting packaged apps to a malicious server.
  if (!app.isPackaged && process.env.VITE_DEV_URL) {
    mainWindow.loadURL(process.env.VITE_DEV_URL)
  } else {
    mainWindow.loadFile(path.join(__dirname, '..', 'dist-react', 'index.html'))
  }

  // Open DevTools in dev mode
  if (!app.isPackaged) {
    mainWindow.webContents.openDevTools({ mode: 'detach' })
  }

  // Open external links in system browser
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (url.startsWith('http')) shell.openExternal(url)
    return { action: 'deny' }
  })

  // Security: block navigation away from the app's origin. A renderer compromise
  // could otherwise navigate to an attacker-controlled page with preload APIs active.
  mainWindow.webContents.on('will-navigate', (event, url) => {
    const devUrl = !app.isPackaged && process.env.VITE_DEV_URL
    if (url.startsWith('file://')) return
    if (devUrl && url.startsWith(devUrl)) return
    event.preventDefault()
    if (url.startsWith('http')) shell.openExternal(url)
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
      return new Response('No subtitles', { status: 404, headers: { 'Access-Control-Allow-Origin': '*' } })
    }

    // Shift timestamps so cues align with video.currentTime (which starts at 0 after each seek)
    const seekBase = playbackIpc.getCurrentSeekBase()
    const shifted = shiftVtt(rawSubtitleCache, seekBase)

    return new Response(shifted, {
      headers: {
        'Content-Type': 'text/vtt; charset=utf-8',
        'Cache-Control': 'no-cache',
        'Access-Control-Allow-Origin': '*',
      },
    })
  })

  // Open database
  try {
    db.open()
  } catch (err) {
    const { dialog } = require('electron')
    dialog.showErrorBox('Database Error', err.message || 'Failed to open the database. The app will now quit.')
    app.quit()
    return
  }

  // Startup sync check (async, fire-and-forget — must not block app startup)
  dbSync.syncOnStartup().catch(err => console.warn('DbSync: startup sync error —', err.message))

  createWindow()

  // Check for updates in packaged builds (fire-and-forget).
  // Run with SIMULATE_UPDATE=1 in dev to test the update UI without a real release.
  if (app.isPackaged || process.env.SIMULATE_UPDATE) {
    const updater = require('./services/updater')
    const checkFn = process.env.SIMULATE_UPDATE
      ? () => Promise.resolve({ version: '99.0.0', assetUrl: null, assetName: 'Caramba-99.0.0.dmg' })
      : updater.checkForUpdate.bind(updater)

    checkFn()
      .then(info => {
        updaterIpc.setPendingInfo(info)
        if (!info || !mainWindow) return
        mainWindow.webContents.send('updater:update-available', info)
      })
      .catch(err => console.warn('Updater: check failed —', err.message))
  }

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})

app.on('window-all-closed', () => {
  transcoder.stop()
  app.quit()
})

// Ensure ffmpeg processes are killed even on abrupt exit
process.on('exit', () => { transcoder.stop() })

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
