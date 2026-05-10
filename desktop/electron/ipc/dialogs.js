// IPC handler for the native folder picker (downloads destination only).

const { ipcMain, dialog } = require('electron')

function register(mainWindow) {
  ipcMain.handle('dialog:selectFolder', async () => {
    const result = await dialog.showOpenDialog(mainWindow, {
      properties: ['openDirectory'],
    })
    if (result.canceled || result.filePaths.length === 0) return null
    return result.filePaths[0]
  })
}

module.exports = { register }
