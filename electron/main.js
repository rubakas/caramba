const { app, BrowserWindow, shell } = require('electron')
const path = require('path')
const db = require('./db')
const dbSync = require('./services/db-sync')

// IPC modules
const seriesIpc = require('./ipc/series')
const episodesIpc = require('./ipc/episodes')
const moviesIpc = require('./ipc/movies')
const playbackIpc = require('./ipc/playback')
const historyIpc = require('./ipc/history')
const settingsIpc = require('./ipc/settings')
const dialogsIpc = require('./ipc/dialogs')

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

app.whenReady().then(() => {
  // Open database
  db.open()

  // Startup sync check
  dbSync.syncOnStartup()

  createWindow()

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})

app.on('window-all-closed', () => {
  dbSync.stopPeriodicSync()
  db.close()
  if (process.platform !== 'darwin') app.quit()
})

app.on('before-quit', () => {
  dbSync.stopPeriodicSync()
  db.close()
})
