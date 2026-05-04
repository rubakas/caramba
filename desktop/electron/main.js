const Sentry = require('./sentry')
const { app, BrowserWindow, shell, ipcMain } = require('electron')
const path = require('path')
const fs = require('fs')
const db = require('./db')
const dbSync = require('./services/db-sync')
const vlcEmbed = require('./services/vlc-embed-player')

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

let mainWindow = null

function createWindow() {
  const windowOpts = {
    width: 1280,
    height: 860,
    minWidth: 800,
    minHeight: 600,
    // Transparent so libVLC's NSView (added behind Chromium's by
    // vlc-embed-player) is visible through the React UI's transparent
    // body region.
    transparent: true,
    backgroundColor: '#00000000',
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

  // Register IPC handlers (dialogs needs the window reference;
  // playback needs it for the libVLC NSView embed).
  showsIpc.register()
  episodesIpc.register()
  moviesIpc.register()
  playbackIpc.register(mainWindow)
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

app.whenReady().then(() => {
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
  vlcEmbed.stop().catch(() => {})
  app.quit()
})

// Ensure libvlc is shut down on abrupt exit too.
process.on('exit', () => { try { vlcEmbed.stop() } catch {} })

let isQuitting = false
app.on('before-quit', (e) => {
  if (isQuitting) return // prevent infinite loop from app.quit() below
  isQuitting = true
  e.preventDefault()
  vlcEmbed.stop().catch(() => {})
  dbSync.dump()
    .catch(err => console.warn('DbSync: dump on quit failed —', err.message))
    .finally(() => {
      db.close()
      app.quit()
    })
})

module.exports = {}
