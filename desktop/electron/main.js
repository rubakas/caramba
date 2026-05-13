const Sentry = require('./sentry')
const { app, BrowserWindow, shell, ipcMain } = require('electron')
const path = require('path')
const fs = require('fs')

// IPC modules — server-only desktop. No SQLite, no library scanning, no
// metadata fetching, no transcoder; the Rails server owns all of that.
const settingsIpc = require('./ipc/settings')
const dialogsIpc = require('./ipc/dialogs')
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
    backgroundColor: '#000000',
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

  // Register IPC handlers. dialogs needs the window to anchor the file-picker sheet.
  settingsIpc.register()
  dialogsIpc.register(mainWindow)
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

  if (!app.isPackaged && process.env.VITE_DEV_URL) {
    mainWindow.loadURL(process.env.VITE_DEV_URL)
  } else {
    mainWindow.loadFile(path.join(__dirname, '..', 'dist-react', 'index.html'))
  }

  if (!app.isPackaged) {
    mainWindow.webContents.openDevTools({ mode: 'detach' })
  }

  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (url.startsWith('http')) shell.openExternal(url)
    return { action: 'deny' }
  })

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
  app.quit()
})

module.exports = {}
