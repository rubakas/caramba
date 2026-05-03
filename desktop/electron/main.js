const Sentry = require('./sentry')
const { app, BrowserWindow, shell, protocol, net, ipcMain } = require('electron')
const path = require('path')
const fs = require('fs')
const { Readable } = require('stream')
const db = require('./db')
const dbSync = require('./services/db-sync')
const transcoder = require('./services/transcoder')

// IPC modules
const showsIpc = require('./ipc/shows')
const episodesIpc = require('./ipc/episodes')
const moviesIpc = require('./ipc/movies')
const playbackIpc = require('./ipc/playback')
const settingsIpc = require('./ipc/settings')
const dialogsIpc = require('./ipc/dialogs')
const updaterIpc = require('./ipc/updater')
const downloadsIpc = require('./ipc/downloads')
const discoveryIpc = require('./ipc/discovery')

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

// Content-type guess for the small set of containers we mark as direct-play
// in the transcoder. Anything outside this set goes through ffmpeg → fMP4.
const DIRECT_PLAY_CONTENT_TYPE = {
  '.mp4': 'video/mp4',
  '.m4v': 'video/mp4',
  '.mov': 'video/quicktime',
}

// Serve the active direct-play file with HTTP Range support so the
// renderer's <video> element can seek by byte. Returns 416 on out-of-range
// requests, 206 for partial content, 200 for full reads.
async function serveDirectPlay(request) {
  if (!transcoder.isDirectPlay()) {
    return new Response('No direct-play session', { status: 404 })
  }
  const filePath = transcoder.getActiveFilePath()
  if (!filePath || !fs.existsSync(filePath)) {
    return new Response('Source file gone', { status: 404 })
  }

  const stat = fs.statSync(filePath)
  const total = stat.size
  const ext = path.extname(filePath).toLowerCase()
  const contentType = DIRECT_PLAY_CONTENT_TYPE[ext] || 'video/mp4'

  const range = request.headers.get('Range')
  if (!range) {
    const stream = Readable.toWeb(fs.createReadStream(filePath))
    return new Response(stream, {
      status: 200,
      headers: {
        'Content-Type': contentType,
        'Content-Length': String(total),
        'Accept-Ranges': 'bytes',
        'Cache-Control': 'no-store',
      },
    })
  }

  const match = /bytes=(\d*)-(\d*)/.exec(range)
  if (!match) {
    return new Response('Bad Range', { status: 400 })
  }
  let start = match[1] === '' ? null : parseInt(match[1], 10)
  let end = match[2] === '' ? null : parseInt(match[2], 10)
  if (start === null && end !== null) {
    // suffix range: last `end` bytes
    start = Math.max(0, total - end)
    end = total - 1
  } else if (start !== null && end === null) {
    end = total - 1
  }
  if (start === null || end === null || start > end || start >= total) {
    return new Response('Range Not Satisfiable', {
      status: 416,
      headers: { 'Content-Range': `bytes */${total}` },
    })
  }
  if (end >= total) end = total - 1

  const stream = Readable.toWeb(fs.createReadStream(filePath, { start, end }))
  return new Response(stream, {
    status: 206,
    headers: {
      'Content-Type': contentType,
      'Content-Range': `bytes ${start}-${end}/${total}`,
      'Content-Length': String(end - start + 1),
      'Accept-Ranges': 'bytes',
      'Cache-Control': 'no-store',
    },
  })
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
  showsIpc.register()
  episodesIpc.register()
  moviesIpc.register()
  playbackIpc.register()
  settingsIpc.register()
  dialogsIpc.register(mainWindow)
  updaterIpc.register(mainWindow)
  downloadsIpc.register()
  discoveryIpc.register()

  // Dev-only: save glass config to src/config/glass.json for playground persistence
  if (!app.isPackaged) {
    ipcMain.handle('dev:saveGlassConfig', async (_event, config) => {
      const configPath = path.join(__dirname, '..', '..', 'ui', 'config', 'glass.json')
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
  // Register stream:// protocol — serves HLS manifest and segments from the
  // transcoder session directory. Requests look like:
  //   stream://video/playlist.m3u8
  //   stream://video/init.mp4
  //   stream://video/segment_42.m4s
  // The `stream:` scheme is non-special under WHATWG URL rules, so different
  // Electron versions disagree on pathname parsing. Pull the last path
  // component off the raw URL directly to stay safe.
  protocol.handle('stream', async (request) => {
    // direct_play branch: stream://direct/<anything>?... — serve the
    // currently-active source file as-is with Range support. The
    // renderer's <video> element drives seeks via byte ranges.
    if (/^stream:\/\/direct(\/|\?|$)/i.test(request.url)) {
      return serveDirectPlay(request)
    }

    const pathPart = request.url.replace(/^stream:\/\/[^/]*\/?/, '').split('?')[0]
    const assetName = pathPart || 'playlist.m3u8'

    const resolved = transcoder.resolveAsset(assetName)
    if (resolved.status === 'bad_name') {
      console.warn(`[stream://] 400 bad asset name: ${assetName}`)
      return new Response('Bad asset', { status: 400 })
    }
    if (resolved.status === 'no_session') {
      // No active transcoder yet (e.g. mid-seek before the new session has
      // been installed). Return 404 so hls.js retries instead of giving up.
      console.warn(`[stream://] 404 no_session for ${assetName} — activeDir is null. Likely strategy resolved to direct_play but the renderer requested an HLS asset.`)
      return new Response('No active session', { status: 404 })
    }
    const assetPath = resolved.path

    const isPlaylist = assetName === 'playlist.m3u8'

    // ffmpeg writes the playlist and segments on its own schedule. The
    // playlist takes longest on first start because ffmpeg has to read
    // analyzeduration of input + warm up zscale/tonemap (HDR 4K sources)
    // + finish the first GOP before flushing the manifest. Segments after
    // the first arrive on the 6s segment cadence + ~2s encode lag at 1×
    // realtime, so 10s gives headroom without making genuine failures
    // hang too long.
    const timeoutMs = isPlaylist ? 12000 : 10000
    const pollEveryMs = 150
    const started = Date.now()
    while (!fs.existsSync(assetPath) && Date.now() - started < timeoutMs) {
      await new Promise(r => setTimeout(r, pollEveryMs))
    }

    if (!fs.existsSync(assetPath)) {
      console.warn(`[stream://] 404 ${assetName} not written by ffmpeg within ${timeoutMs}ms (path=${assetPath}). Most likely ffmpeg failed to start — check the Transcoder: lines above.`)
      return new Response('Not ready', { status: 404 })
    }

    if (isPlaylist) {
      let text = fs.readFileSync(assetPath, 'utf8')
      // If ffmpeg has exited without writing ENDLIST, append it so hls.js
      // stops polling for more segments.
      if (!transcoder.isActive() && !text.includes('#EXT-X-ENDLIST')) {
        text = text.trimEnd() + '\n#EXT-X-ENDLIST\n'
      }
      return new Response(text, {
        headers: {
          'Content-Type': 'application/vnd.apple.mpegurl',
          'Cache-Control': 'no-store',
        },
      })
    }

    const body = fs.readFileSync(assetPath)
    return new Response(body, {
      headers: {
        'Content-Type': 'video/mp4',
        // Must not cache: segment filenames reset to segment_0 on every
        // seek/session restart, so the same URL carries different content
        // across sessions. Caching would hand back stale bytes and desync
        // hls.js's PTS tracking.
        'Cache-Control': 'no-store',
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
