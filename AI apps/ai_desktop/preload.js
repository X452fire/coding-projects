const { contextBridge, ipcRenderer, webUtils } = require('electron')

contextBridge.exposeInMainWorld('electronAPI', {
    captureScreen: () => ipcRenderer.invoke('capture-screen'),
    launchApp: (path) => ipcRenderer.invoke('launch-app', path),
    getPathForFile: (file) => webUtils.getPathForFile(file)
})
