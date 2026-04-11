// IPC handlers for watch history

const { ipcMain } = require('electron')
const db = require('../db')

function register() {
  ipcMain.handle('history:list', (_e, limit = 100) => {
    return db.watchHistories.recent(limit)
  })

  ipcMain.handle('history:stats', () => {
    return db.watchHistories.stats()
  })
}

module.exports = { register }
