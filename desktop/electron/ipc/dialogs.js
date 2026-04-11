// IPC handlers for native OS dialogs (folder/file pickers)

const { ipcMain, dialog } = require('electron')

function register(mainWindow) {
  ipcMain.handle('dialog:selectFolder', async () => {
    const result = await dialog.showOpenDialog(mainWindow, {
      properties: ['openDirectory'],
    })
    if (result.canceled || result.filePaths.length === 0) return null
    return result.filePaths[0]
  })

  ipcMain.handle('dialog:selectFiles', async () => {
    const result = await dialog.showOpenDialog(mainWindow, {
      properties: ['openFile', 'multiSelections'],
      filters: [
        { name: 'Video Files', extensions: ['mkv', 'mp4', 'avi', 'mov', 'm4v'] },
      ],
    })
    if (result.canceled || result.filePaths.length === 0) return []
    return result.filePaths
  })
}

module.exports = { register }
