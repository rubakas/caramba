const Sentry = require('./sentry')
const { app, BrowserWindow, shell, ipcMain } = require('electron')
const path = require('path')
const fs = require('fs')
const mpvEmbed = require('./services/mpv-embed-player')

// IPC modules — server-only desktop. No SQLite, no library scanning, no
// metadata fetching, no transcoder; the Rails server owns all of that.
const settingsIpc = require('./ipc/settings')
const dialogsIpc = require('./ipc/dialogs')
const mpvEmbedIpc = require('./ipc/mpv-embed')
const vlcIpc = require('./ipc/vlc')
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

  if (process.platform === 'darwin') {
    windowOpts.titleBarStyle = 'hiddenInset'
    windowOpts.trafficLightPosition = { x: 16, y: 16 }
  }

  mainWindow = new BrowserWindow(windowOpts)

  // Register IPC handlers. mpv-embed needs the window for getNativeWindowHandle();
  // dialogs needs it to anchor the file-picker sheet.
  settingsIpc.register()
  dialogsIpc.register(mainWindow)
  mpvEmbedIpc.register(mainWindow)
  vlcIpc.register(mainWindow)
  updaterIpc.register(mainWindow)
  downloadsIpc.register()
  discoveryIpc.register()

  // Dev-only: save glass config to ui/config/glass.json for Playground.
  if (!app.isPackaged) {
    ipcMain.handle('dev:saveGlassConfig', async (_event, config) => {
      const configPath = path.join(__dirname, '..', '..', 'ui', 'config', 'glass.json')
      fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + '\n', 'utf-8')
      return { ok: true }
    })
  }

  // Security: only allow VITE_DEV_URL in development builds to prevent
  // env-var poisoning from redirecting packaged apps to a malicious server.
  if (!app.isPackaged && process.env.VITE_DEV_URL) {
    mainWindow.loadURL(process.env.VITE_DEV_URL)
  } else {
    mainWindow.loadFile(path.join(__dirname, '..', 'dist-react', 'index.html'))
  }

  if (!app.isPackaged) {
    mainWindow.webContents.openDevTools({ mode: 'detach' })
  }

  // Open external links in system browser
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (url.startsWith('http')) shell.openExternal(url)
    return { action: 'deny' }
  })

  // Block navigation away from the app's origin. A renderer compromise
  // could otherwise navigate to an attacker-controlled page with the
  // preload bridge active.
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
  mpvEmbed.stop().catch(() => {})
  app.quit()
})

// Ensure libmpv is shut down on abrupt exit too.
process.on('exit', () => { try { mpvEmbed.stop() } catch {} })

let isQuitting = false
app.on('before-quit', (e) => {
  if (isQuitting) return
  isQuitting = true
  e.preventDefault()
  mpvEmbed.stop().catch(() => {}).finally(() => app.quit())
})

module.exports = {}
