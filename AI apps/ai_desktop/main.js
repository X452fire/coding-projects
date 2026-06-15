const { app, BrowserWindow, ipcMain, desktopCapturer, shell } = require('electron')
const path = require('path')

function createWindow() {
    const win = new BrowserWindow({
        width: 1200,
        height: 800,
        webPreferences: {
            preload: path.join(__dirname, 'preload.js'),
            nodeIntegration: false,
            contextIsolation: true
        }
    })

    win.loadFile('AI.html')
    // win.webContents.openDevTools() // Optional: Enable for debugging
}

app.whenReady().then(() => {
    createWindow()

    // Handler: Screenshot
    ipcMain.handle('capture-screen', async () => {
        try {
            const sources = await desktopCapturer.getSources({ types: ['screen'] })
            // Prefer primary display
            const primarySource = sources[0]
            return {
                status: 'success',
                dataUrl: primarySource.thumbnail.toDataURL()
            }
        } catch (error) {
            return { status: 'error', message: error.message }
        }
    })

    // Handler: Launch App / File
    ipcMain.handle('launch-app', async (event, filePath) => {
        try {
            const result = await shell.openPath(filePath)
            if (result) {
                // shell.openPath returns error string if failed, empty string if success
                return { status: 'error', message: result }
            }
            return { status: 'success' }
        } catch (error) {
            return { status: 'error', message: error.message }
        }
    })

    app.on('activate', () => {
        if (BrowserWindow.getAllWindows().length === 0) {
            createWindow()
        }
    })
})

app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') {
        app.quit()
    }
})
