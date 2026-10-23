'use strict';
const { app, BrowserWindow, WebContentsView, ipcMain, dialog, clipboard, shell, session, nativeImage, Menu } = require('electron');
const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { DownloadLibrary, platform, webURL, PLATFORMS, runTool } = require('./core.cjs');
const { resolveDirect, metadata, videoID } = require('./douyin.cjs');
const smoke = process.argv.includes('--vidtuck-smoke');
const smokeRoot = process.env.VIDTUCK_SMOKE_DIR;
app.setName('VidTuck');
if (smoke && smokeRoot) app.setPath('userData', path.join(smokeRoot, 'profile'));
const primaryInstance = smoke || app.requestSingleInstanceLock();
if (!primaryInstance) app.quit();
let mainWindow, library, webSession;
const helpers = new Set(), coverPending = new Set();
const appRoot = path.resolve(__dirname, '..');
const uiURL = pathToFileURL(path.join(appRoot, 'ui', 'index.html')).href;
const helperURL = pathToFileURL(path.join(__dirname, 'helper.html')).href;
const send = (type, payload) => { if (mainWindow && !mainWindow.isDestroyed()) mainWindow.webContents.send('vidtuck:message', { type, payload }); };
function allowedPage(value) { const u = webURL(value); return !!u && u.protocol === 'https:' && platform(value) !== '其他'; }
function allowedNavigation(value) { const u = webURL(value); return allowedPage(value) || !!u && u.protocol === 'https:' && u.hostname === 'accounts.google.com'; }
function lockWebContents(wc) {
  wc.setWindowOpenHandler(() => ({ action: 'deny' }));
  wc.on('will-attach-webview', e => e.preventDefault());
}
async function cacheCover(job) {
  if (!webURL(job.thumbnail) || coverPending.has(job.thumbnail)) return;
  coverPending.add(job.thumbnail);
  try {
    const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 10000);
    try {
      const r = await session.defaultSession.fetch(job.thumbnail, { signal: controller.signal });
      if (!r.ok || !r.headers.get('content-type')?.startsWith('image/')) return;
      const reader = r.body.getReader(); let chunks = [], size = 0;
      while (true) { const { done, value } = await reader.read(); if (done) break; size += value.length; if (size > 6000000) { await reader.cancel(); return; } chunks.push(Buffer.from(value)); }
      const image = nativeImage.createFromBuffer(Buffer.concat(chunks));
      if (!image.isEmpty() && library.state.jobs.includes(job)) { job.cover = 'data:image/jpeg;base64,' + image.resize({ width: 700 }).toJPEG(75).toString('base64'); library.changed(); }
    } finally { clearTimeout(timer); }
  } catch {} finally { coverPending.delete(job.thumbnail); }
}
async function exportCookies(p) {
  if (!Object.hasOwn(PLATFORMS, p)) return;
  const cookies = (await webSession.cookies.get({})).filter(c => PLATFORMS[p].some(d => c.domain.replace(/^\./, '') === d || c.domain.endsWith('.' + d)));
  if (!cookies.length) return;
  const lines = ['# Netscape HTTP Cookie File', '# VidTuck independent browser session'];
  for (const c of cookies) {
    if ([c.domain, c.path, c.name, c.value].some(v => /[\r\n\t]/.test(v))) continue;
    lines.push([c.httpOnly ? '#HttpOnly_' + c.domain : c.domain, c.hostOnly ? 'FALSE' : 'TRUE', c.path || '/', c.secure ? 'TRUE' : 'FALSE', Math.floor(c.expirationDate || 0), c.name, c.value].join('\t'));
  }
  fs.writeFileSync(library.cookieURL(p), lines.join('\n') + '\n', { mode: 0o600 }); library.changed();
}
function openHelper(url, jobID) {
  if (!allowedPage(url)) { library.toast('网页辅助支持 YouTube、B站、抖音和小红书的 HTTPS 页面'); return; }
  const win = new BrowserWindow({ width: 1120, height: 800, minWidth: 700, minHeight: 500, title: 'VidTuck · 网页辅助', backgroundColor: '#292929', webPreferences: { preload: path.join(__dirname, 'preload.cjs'), nodeIntegration: false, contextIsolation: true, sandbox: true } });
  const view = new WebContentsView({ webPreferences: { session: webSession, nodeIntegration: false, contextIsolation: true, sandbox: true } });
  helpers.add(win); win.contentView.addChildView(view);
  const fit = () => { const [width, height] = win.getContentSize(); view.setBounds({ x: 0, y: 110, width, height: Math.max(0, height - 110) }); }; fit(); win.on('resize', fit);
  const status = text => { if (!win.isDestroyed()) win.webContents.send('vidtuck:message', { type: 'status', payload: text }); };
  const address = () => { if (!win.isDestroyed()) win.webContents.send('vidtuck:message', { type: 'address', payload: view.webContents.getURL() }); };
  lockWebContents(win.webContents); lockWebContents(view.webContents);
  win.webContents.on('will-navigate', e => e.preventDefault());
  const guard = (e, next) => { if (!allowedNavigation(next)) { e.preventDefault(); status('此链接不属于支持的平台，已停止跳转'); } };
  view.webContents.on('will-navigate', guard); view.webContents.on('will-redirect', guard);
  view.webContents.setWindowOpenHandler(({ url }) => { if (allowedNavigation(url)) view.webContents.loadURL(url).catch(() => {}); return { action: 'deny' }; });
  view.webContents.on('did-navigate', address); view.webContents.on('did-navigate-in-page', address);
  view.webContents.on('did-fail-load', (_e, code) => { if (code !== -3) status('页面加载未完成，请检查网络或重新打开'); });
  win.webContents.on('did-finish-load', () => { address(); status('登录或播放目标视频后，点击“读取此页”'); });
  const actions = async (event, message) => {
    if (event.sender !== win.webContents || event.senderFrame !== win.webContents.mainFrame || event.senderFrame.url !== helperURL || !message || typeof message.action !== 'string') return;
    try {
      if (message.action === 'helperGo') { if (allowedNavigation(message.url)) await view.webContents.loadURL(message.url); else status('请输入支持平台的 HTTPS 视频链接'); }
      else if (message.action === 'helperBack' && view.webContents.navigationHistory.canGoBack()) view.webContents.navigationHistory.goBack();
      else if (message.action === 'helperRead') {
        const page = view.webContents.getURL(); if (!allowedPage(page)) { status('完成登录后，请返回目标视频网页，再点击读取此页'); return; }
        const p = platform(page); await exportCookies(p);
        let job = library.state.jobs.find(j => j.id === jobID);
        if (job && library.active?.id === job.id) { status('请先在主窗口暂停此任务，再读取网页'); return; }
        if (!job) { library.add(page); job = library.state.jobs[0]; status('已添加当前网页，并使用本应用登录信息解析'); return; }
        if (p === '抖音') {
          const value = await view.webContents.executeJavaScript(`(() => { const values=[window.__streamNestVideo,window._ROUTER_DATA,window.__INITIAL_STATE__]; for(const el of document.querySelectorAll('script[type="application/json"],script#RENDER_DATA')){try{values.push(JSON.parse(decodeURIComponent(el.textContent)))}catch{try{values.push(JSON.parse(el.textContent))}catch{}}} return values.filter(Boolean) })()`);
          const id = videoID(page), info = id && metadata(value, id, page);
          if (info) { library.dropInfo(job); job.url = page; job.platform = p; library.setMetadata(job, info); void library.pump(); status('已读取视频并加入下载队列'); return; }
        }
        library.dropInfo(job); library.mutate(job, { url: page, platform: p, state: 'pending', refreshed: false, error: '' }); void library.pump(); status('已保存本应用登录状态，正在重新解析此页');
      }
    } catch { status('读取未完成，请确认打开的是单条视频，并完成登录或验证后重试'); }
  };
  ipcMain.on('vidtuck:action', actions);
  win.on('closed', () => { ipcMain.removeListener('vidtuck:action', actions); helpers.delete(win); if (!view.webContents.isDestroyed()) view.webContents.close(); });
  win.loadFile(path.join(__dirname, 'helper.html')); view.webContents.loadURL(url).catch(() => {});
}

async function action(message) {
  const id = typeof message.id === 'string' ? message.id : '';
  const j = library.state.jobs.find(j => j.id === id);
  switch (message.action) {
    case 'ready': send('state', library.snapshot()); break;
    case 'paste': send('paste', clipboard.readText()); break;
    case 'add': if (typeof message.text === 'string' && message.text.length < 100000) library.add(message.text); break;
    case 'start': library.start(id); break;
    case 'startAll': library.state.jobs.filter(j => ['ready', 'paused', 'failed'].includes(j.state)).forEach(j => library.start(j.id)); break;
    case 'pause': library.pause(id); break;
    case 'remove': library.remove(id); break;
    case 'clearDone': library.state.jobs = library.state.jobs.filter(j => j.state !== 'done'); library.changed(); break;
    case 'autoDownload': library.state.autoDownload = message.value === true; library.changed(); break;
    case 'options': {
      const quality = message.quality, mode = message.mode;
      if (!['best', '2160', '1080', '720', '480'].includes(quality) || !['video', 'audio'].includes(mode)) return;
      if (id) { if (j && !['analyzing', 'downloading', 'done'].includes(j.state)) library.mutate(j, { quality, mode }); }
      else { library.state.quality = quality; library.state.mode = mode; library.changed(); } break;
    }
    case 'folder': { const r = await dialog.showOpenDialog(mainWindow, { title: '选择视频保存位置', defaultPath: library.state.destination, properties: ['openDirectory', 'createDirectory'] }); if (!r.canceled && r.filePaths[0]) { library.state.destination = r.filePaths[0]; library.changed(); } break; }
    case 'openFolder': fs.mkdirSync(library.state.destination, { recursive: true }); { const error = await shell.openPath(library.state.destination); if (error) library.toast('无法打开保存文件夹'); } break;
    case 'reveal': if (j?.file && fs.existsSync(j.file)) shell.showItemInFolder(j.file); else library.toast('文件已被移动或删除'); break;
    case 'play': if (j?.file && fs.existsSync(j.file) && /\.(mp4|mkv|webm|m4a|mp3|mov|ogg|opus|flac|wav)$/i.test(j.file)) { const error = await shell.openPath(j.file); if (error) library.toast('系统没有可打开此格式的播放器，请用“显示文件”选择兼容播放器'); } else library.toast('文件已被移动、删除或不属于媒体格式'); break;
    case 'browse': openHelper(j?.url || message.url || 'https://www.douyin.com/', j?.id); break;
    case 'update': await library.updateEngine(); break;
    case 'importCookies': {
      if (!Object.hasOwn(PLATFORMS, message.platform)) return;
      const r = await dialog.showOpenDialog(mainWindow, { title: '导入自己的 Netscape cookies.txt', filters: [{ name: 'Cookie 文本', extensions: ['txt'] }], properties: ['openFile'] });
      if (!r.canceled && r.filePaths[0]) {
        if (fs.statSync(r.filePaths[0]).size > 5000000) throw Error('Cookie 文件太大');
        const data = fs.readFileSync(r.filePaths[0], 'utf8');
        if (!data.split(/\r?\n/).some(line => /^(?:#HttpOnly_)?[^#\s][^\t]*\t(?:TRUE|FALSE)\t/.test(line))) throw Error('请选择 Netscape cookies.txt 格式');
        fs.writeFileSync(library.cookieURL(message.platform), data, { mode: 0o600 }); library.changed(); library.toast('已导入本人的登录信息');
      } break;
    }
    case 'clearLogin': {
      if (library.active) { library.toast('请先暂停当前任务，再清除登录信息'); return; }
      const r = await dialog.showMessageBox(mainWindow, { type: 'question', buttons: ['取消', '清除'], defaultId: 0, cancelId: 0, message: '清除 VidTuck 网页辅助的登录状态？', detail: '不会影响 Chrome、Edge 等其他浏览器。' });
      if (r.response === 1) { for (const helper of helpers) helper.close(); await webSession.clearStorageData(); for (const p of Object.keys(PLATFORMS)) fs.rmSync(library.cookieURL(p), { force: true }); library.changed(); } break;
    }
  }
}
async function ready() {
  const root = smoke && smokeRoot ? smokeRoot : app.getPath('userData');
  const support = path.join(root, 'data');
  const tools = process.env.VIDTUCK_TOOLS || path.join(process.resourcesPath, 'tools');
  library = new DownloadLibrary({ support, tools, destination: path.join(smoke && smokeRoot ? smokeRoot : app.getPath('downloads'), 'VidTuck') });
  webSession = session.fromPartition('persist:vidtuck-web');
  webSession.setPermissionRequestHandler((_wc, _permission, callback) => callback(false)); webSession.setPermissionCheckHandler(() => false);
  library.resolveDouyin = (j, t) => resolveDirect(j.url, webSession, t);
  mainWindow = new BrowserWindow({ width: 650, height: 470, minWidth: 500, minHeight: 350, title: 'VidTuck', backgroundColor: '#292929', show: !smoke, icon: path.join(appRoot, 'ui', 'AppIcon.png'), webPreferences: { preload: path.join(__dirname, 'preload.cjs'), nodeIntegration: false, contextIsolation: true, sandbox: true, partition: 'vidtuck-ui' } });
  lockWebContents(mainWindow.webContents); mainWindow.webContents.on('will-navigate', e => e.preventDefault());
  mainWindow.webContents.session.setPermissionRequestHandler((_wc, _permission, callback) => callback(false));
  library.on('state', state => send('state', state)); library.on('toast', text => send('toast', text)); library.on('thumbnail', cacheCover);
  ipcMain.on('vidtuck:action', (event, message) => {
    if (event.sender !== mainWindow?.webContents || event.senderFrame !== mainWindow.webContents.mainFrame || event.senderFrame.url !== uiURL || !message || typeof message.action !== 'string') return;
    void action(message).catch(e => library.toast('操作未完成：' + e.message));
  });
  Menu.setApplicationMenu(Menu.buildFromTemplate([{ label: '文件', submenu: [{ label: '粘贴链接', click: () => send('paste', clipboard.readText()) }, { label: '设置', accelerator: 'CommandOrControl+,', click: () => send('settings', '') }, { type: 'separator' }, { role: 'quit', label: '退出 VidTuck' }] }, { label: '编辑', submenu: [{ role: 'undo', label: '撤销' }, { role: 'cut', label: '剪切' }, { role: 'copy', label: '复制' }, { role: 'paste', label: '粘贴' }, { role: 'selectAll', label: '全选' }] }]));
  await mainWindow.loadURL(uiURL); void library.checkVersion();
  mainWindow.on('closed', () => { for (const win of helpers) win.close(); mainWindow = null; app.quit(); });
  if (smoke) {
    try { await require('./smoke.cjs').run({ app, mainWindow, library, tools, root: smokeRoot }); app.exit(0); }
    catch (e) { fs.writeFileSync(path.join(smokeRoot, 'FAILED.txt'), e.stack); app.exit(1); }
  }
}
app.on('second-instance', () => { if (mainWindow) { if (mainWindow.isMinimized()) mainWindow.restore(); mainWindow.show(); mainWindow.focus(); } });
app.on('before-quit', () => { if (library && !library.closed) library.close(); });
app.on('window-all-closed', () => app.quit());
if (primaryInstance) app.whenReady().then(ready).catch(e => { dialog.showErrorBox('VidTuck 无法启动', e.message); app.exit(1); });
