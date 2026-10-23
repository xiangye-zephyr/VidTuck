'use strict';
const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('vidtuck', {
  send: message => ipcRenderer.send('vidtuck:action', message),
  onMessage: callback => ipcRenderer.on('vidtuck:message', (_event, message) => callback(message))
});
