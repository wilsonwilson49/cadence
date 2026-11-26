// Small bridge the Cadence web app looks for (window.cadenceDesktop) when it runs in the desktop app.
const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('cadenceDesktop', {
  platform: process.platform,
  onWake: cb => ipcRenderer.on('cadence:wake', (_e, reason) => cb(reason)),
  // Focus sessions pause when you leave the computer: seconds since the last input anywhere, and going to sleep.
  idleSeconds: () => ipcRenderer.invoke('cadence:idle'),
  onSleep: cb => ipcRenderer.on('cadence:sleep', () => cb()),
  onCommand: cb => ipcRenderer.on('cadence:command', (_e, cmd) => cb(cmd)),
  setBadge: n => ipcRenderer.send('cadence:badge', n),
  getOpenAtLogin: () => ipcRenderer.invoke('cadence:getOpenAtLogin'),
  setOpenAtLogin: on => ipcRenderer.send('cadence:setOpenAtLogin', on),
});
