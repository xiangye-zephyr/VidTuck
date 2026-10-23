'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { randomUUID } = require('node:crypto');
const { EventEmitter } = require('node:events');

const ACTIVE = new Set(['pending', 'analyzing', 'queued', 'downloading']);
const PLATFORMS = { YouTube: ['youtube.com', 'youtu.be'], 'B站': ['bilibili.com', 'b23.tv'], '抖音': ['douyin.com', 'iesdouyin.com'], '小红书': ['xiaohongshu.com', 'xhslink.com'] };
function webURL(value) {
  try { const u = new URL(value); return ['http:', 'https:'].includes(u.protocol) && !!u.hostname && !u.username && !u.password ? u : null; } catch { return null; }
}
function platform(value) {
  const host = webURL(value)?.hostname.toLowerCase() || '';
  return Object.keys(PLATFORMS).find(p => PLATFORMS[p].some(d => host === d || host.endsWith('.' + d))) || '其他';
}
function urls(text) {
  return [...new Set((String(text).match(/https?:\/\/[^\s<>"'\u3000]+/gi) || []).map(s => s.replace(/[，。；、）】》」！？,;!?)\]}]+$/u, '')).filter(s => webURL(s)))].slice(0, 50);
}
function safeLog(text) {
  return String(text).replace(/https?:\/\/[^\s]+/gi, '[链接已隐藏]').replace(/(?:cookie|authorization|xsec_token|msToken|token)[:=]\s*[^\s,;]+/gi, '[凭据已隐藏]').slice(-2400);
}
function friendlyError(raw) {
  const s = String(raw);
  const hint = /cookies|login|sign in|403|412|verify|captcha/i.test(s) ? '网站要求登录或验证，可用网页辅助登录后读取此页。' : /requested format/i.test(s) ? '没有符合清晰度要求的视频，请改为最高可用后重试。' : /timed out|network|connection|ENOTFOUND/i.test(s) ? '网络连接失败或超时，请检查网络后重试。' : '未取得可下载的视频，可重试、更新解析器或使用网页辅助。';
  return hint + '\n' + safeLog(s.split(/\r?\n/).filter(Boolean).slice(-3).join('\n'));
}
function within(file, dir) {
  const relative = path.relative(fs.realpathSync(dir), fs.realpathSync(file));
  return !!relative && !relative.startsWith('..' + path.sep) && relative !== '..' && !path.isAbsolute(relative);
}
function runTool(executable, args, { onLine = () => {}, timeout = 150000, env = {}, cwd, spawnImpl = spawn } = {}) {
  let child, timer, killed = false;
  const promise = new Promise(resolve => {
    let stdout = '', stderr = '', outPending = '', errPending = '', settled = false;
    const finish = (code, error = '') => {
      if (settled) return;
      settled = true; clearTimeout(timer);
      if (outPending) onLine(outPending); if (errPending) onLine(errPending);
      resolve({ code, stdout, stderr: error || stderr });
    };
    try { child = spawnImpl(executable, args, { shell: false, windowsHide: true, cwd, env: { ...process.env, PYTHONIOENCODING: 'utf-8', ...env }, stdio: ['ignore', 'pipe', 'pipe'] }); }
    catch (e) { finish(-1, e.message); return; }
    function receive(chunk, error) {
      const data = chunk.toString();
      if (error) { stderr = (stderr + data).slice(-131072); errPending += data; }
      else { stdout = (stdout + data).slice(-33554432); outPending += data; }
      let pending = error ? errPending : outPending;
      const lines = pending.split(/\r?\n/); pending = lines.pop();
      for (const line of lines) onLine(line);
      if (pending.length > 1048576) pending = '';
      if (error) errPending = pending; else outPending = pending;
    }
    child.stdout.setEncoding('utf8'); child.stderr.setEncoding('utf8');
    child.stdout.on('data', c => receive(c, false)); child.stderr.on('data', c => receive(c, true));
    child.once('error', e => finish(-1, e.message)); child.once('close', code => finish(code ?? -1));
    timer = setTimeout(() => { stderr += '\n请求超时'; stop(); }, timeout); timer.unref?.();
  });
  function stop() {
    if (!child?.pid || killed) return;
    killed = true;
    // yt-dlp may have spawned ffmpeg; terminate only this task's process tree.
    if (process.platform === 'win32') {
      const taskkill = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'taskkill.exe');
      const killer = spawn(taskkill, ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true, shell: false, stdio: 'ignore' });
      killer.on('error', () => child.kill());
    } else { child.kill('SIGTERM'); const t = setTimeout(() => { if (child.exitCode === null) child.kill('SIGKILL'); }, 2500); t.unref(); }
  }
  return { promise, stop };
}

class DownloadLibrary extends EventEmitter {
  constructor({ support, tools, destination, runner = runTool }) {
    super(); this.support = support; this.tools = tools; this.runner = runner; this.active = null; this.updating = false; this.engineVersion = '检查中'; this.closed = false;
    fs.mkdirSync(support, { recursive: true, mode: 0o700 });
    this.state = { jobs: [], destination, quality: 'best', mode: 'video', autoDownload: true };
    const store = path.join(support, 'library.json');
    if (fs.existsSync(store)) {
      try {
        const saved = JSON.parse(fs.readFileSync(store, 'utf8'));
        if (!Array.isArray(saved.jobs) || typeof saved.destination !== 'string') throw Error('记录格式错误');
        this.state = { ...this.state, ...saved };
      } catch {
        // Keep an unreadable database for recovery instead of overwriting it silently.
        fs.copyFileSync(store, store + '.unreadable-' + Date.now());
      }
    }
    for (const j of this.state.jobs) { if (ACTIVE.has(j.state)) { j.state = 'paused'; j.detail = '上次任务已暂停，可继续'; } j.infoFile = null; }
    for (const name of fs.readdirSync(support)) if (/^(extractor|web)-info-[\w-]+\.json$/.test(name)) fs.rmSync(path.join(support, name), { force: true });
  }
  tool(name) { return path.join(this.tools, name + (process.platform === 'win32' ? '.exe' : '')); }
  get executable() { const updated = path.join(this.support, 'tools', 'yt-dlp' + (process.platform === 'win32' ? '.exe' : '')); return fs.existsSync(updated) ? updated : this.tool('yt-dlp'); }
  cookieURL(p) { return path.join(this.support, 'cookies-' + ({ YouTube: 'youtube', 'B站': 'bilibili', '抖音': 'douyin', '小红书': 'xhs' }[p] || 'other') + '.txt'); }
  snapshot() { return { ...this.state, engineVersion: this.engineVersion, updating: this.updating, loggedIn: Object.keys(PLATFORMS).filter(p => fs.existsSync(this.cookieURL(p))) }; }
  changed() {
    const store = path.join(this.support, 'library.json');
    fs.writeFileSync(store + '.tmp', JSON.stringify(this.state, null, 2), { mode: 0o600 }); fs.renameSync(store + '.tmp', store);
    this.emit('state', this.snapshot());
  }
  toast(text) { this.emit('toast', text); }
  mutate(j, values) { Object.assign(j, values); this.changed(); }
  add(text) {
    const list = urls(text); if (!list.length) { this.toast('没有找到有效链接，请粘贴视频网址或分享文案。'); return; }
    let count = 0;
    for (const url of list) {
      if (this.state.jobs.some(j => j.url === url && !['done', 'failed'].includes(j.state))) continue;
      this.state.jobs.unshift({ id: randomUUID(), url, platform: platform(url), title: '正在读取视频信息…', state: 'pending', quality: this.state.quality, mode: this.state.mode, destination: this.state.destination, progress: 0, detail: '等待解析', error: '', file: '', created: Date.now() / 1000 }); count++;
    }
    this.changed(); this.toast(count ? `已加入 ${count} 个链接` : '这些链接已在队列中'); void this.pump();
  }
  baseArgs(j) {
    const args = ['--ignore-config', '--encoding', 'utf-8', '--no-playlist', '--no-colors', '--socket-timeout', '20', '--retries', '2', '--extractor-retries', '1', '--ffmpeg-location', this.tools, '--js-runtimes', 'deno:' + this.tool('deno')];
    if (fs.existsSync(this.cookieURL(j.platform))) args.push('--cookies', this.cookieURL(j.platform));
    return args;
  }
  async pump() {
    if (this.active || this.updating || this.closed) return;
    const pending = [...this.state.jobs].reverse();
    const job = pending.find(j => j.state === 'queued') || pending.find(j => j.state === 'pending');
    if (!job) return;
    const token = { id: job.id, cancel: false, command: null }; this.active = token;
    try { if (job.state === 'pending') await this.analyze(job, token); else await this.download(job, token); }
    catch (e) { if (this.current(job, token)) this.mutate(job, { state: 'failed', detail: '任务未完成', error: friendlyError(e.message) }); }
    finally { if (this.active === token) this.active = null; if (!this.closed) queueMicrotask(() => this.pump()); }
  }
  current(j, t) { return this.active === t && !t.cancel && this.state.jobs.includes(j) && !this.closed; }
  async command(args, token, onLine = () => {}, timeout = 150000) {
    const command = this.runner(this.executable, args, { onLine, timeout }); token.command = command;
    if (token.cancel) command.stop();
    const result = await command.promise; if (token.command === command) token.command = null; return result;
  }
  async analyze(j, t) {
    this.mutate(j, { state: 'analyzing', detail: '正在读取标题与清晰度…', error: '' });
    if (j.platform === '抖音' && this.resolveDouyin) {
      const info = await this.resolveDouyin(j, t);
      if (!this.current(j, t)) return;
      if (info) { this.setMetadata(j, info); return; }
    }
    const r = await this.command([...this.baseArgs(j), '--dump-single-json', '--skip-download', '--', j.url], t);
    if (!this.current(j, t)) return;
    if (r.code !== 0) throw Error(r.stderr || r.stdout || '解析器未返回视频');
    const info = JSON.parse(r.stdout);
    if (info._type === 'playlist' || (!info.formats?.length && !info.url)) throw Error('请使用单条视频链接');
    this.setMetadata(j, info);
  }
  setMetadata(j, info) {
    const infoFile = path.join(this.support, 'extractor-info-' + j.id + '.json');
    fs.writeFileSync(infoFile, JSON.stringify(info), { mode: 0o600 });
    const cap = Number(j.quality) || Infinity;
    const best = (info.formats || []).filter(f => f.height > 0 && f.height <= cap).sort((a, b) => b.height - a.height)[0] || info;
    this.mutate(j, { title: String(info.title || '网页视频').trim() || '网页视频', duration: Number(info.duration) || 0, thumbnail: info.thumbnail || '', mediaWidth: best.width, mediaHeight: best.height, mediaExt: j.mode === 'audio' ? 'm4a' : best.ext, infoFile, metadataAt: Date.now(), state: this.state.autoDownload ? 'queued' : 'ready', detail: '解析完成', error: '' });
    this.emit('thumbnail', j);
  }
  async download(j, t) {
    fs.mkdirSync(j.destination, { recursive: true });
    const temp = path.join(this.support, 'download-temp', j.id); fs.mkdirSync(temp, { recursive: true });
    this.mutate(j, { state: 'downloading', error: '', detail: '正在连接视频源…', file: '' });
    const template = j.mode === 'audio' ? '%(title).100B [%(id)s].audio.%(ext)s' : '%(title).100B [%(id)s].%(ext)s';
    const args = [...this.baseArgs(j), '--newline', '--progress', '--no-simulate', '--no-overwrites', '--windows-filenames', '--trim-filenames', '150', '-P', j.destination, '-P', 'temp:' + temp, '-o', template, '--progress-template', 'download:__PROGRESS__%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s', '--print', 'before_dl:__MEDIA__%(width)s|%(height)s|%(ext)s', '--print', 'after_move:__FILE__%(filepath)s'];
    if (j.mode === 'audio') args.push('-f', 'ba/b', '-x', '--audio-format', 'm4a');
    else { const cap = Number(j.quality) ? `[height<=${Number(j.quality)}]` : ''; args.push('-f', `bv*${cap}+ba/b${cap}`, '--format-sort', 'lang,quality,res,fps,hdr:12,vcodec:h264,channels,acodec:aac', '--merge-output-format', 'mp4/mkv'); }
    const cached = j.infoFile && fs.existsSync(j.infoFile) && Date.now() - j.metadataAt < 600000;
    if (cached) args.push('--load-info-json', j.infoFile); else args.push('--', j.url);
    const r = await this.command(args, t, line => {
      if (!this.current(j, t)) return;
      if (line.startsWith('__PROGRESS__')) { const [p, speed, eta] = line.slice(12).split('|'); this.mutate(j, { progress: Math.max(0, Math.min(100, parseFloat(p) || 0)), detail: `${speed?.trim() || ''} · 剩余 ${eta?.trim() || ''}` }); }
      else if (line.startsWith('__FILE__')) this.mutate(j, { file: line.slice(8).trim() });
      else if (line.startsWith('__MEDIA__')) { const [w, h, ext] = line.slice(9).split('|'); this.mutate(j, { mediaWidth: Number(w) || undefined, mediaHeight: Number(h) || undefined, mediaExt: j.mode === 'audio' ? 'm4a' : ext }); }
      else if (/\[(Merger|ExtractAudio|Fixup)/.test(line)) this.mutate(j, { detail: '正在合并与处理媒体…' });
    }, 21600000);
    if (!this.current(j, t)) return;
    if (r.code === 0 && j.file && fs.existsSync(j.file) && within(j.file, j.destination) && fs.statSync(j.file).size > 0) {
      this.dropInfo(j); this.mutate(j, { state: 'done', progress: 100, fileSize: fs.statSync(j.file).size, detail: '已保存到本机', mediaExt: path.extname(j.file).slice(1) });
      fs.rmSync(temp, { recursive: true, force: true }); this.toast('下载完成：' + j.title);
    } else if (cached && !j.refreshed) {
      this.dropInfo(j); this.mutate(j, { state: 'pending', refreshed: true, progress: 0, file: '', detail: '正在刷新视频链接…' });
    } else throw Error(r.stderr || '未获得完整媒体文件，请重新解析');
  }
  dropInfo(j) { if (j.infoFile && path.dirname(j.infoFile) === this.support && /^(extractor|web)-info-/.test(path.basename(j.infoFile))) fs.rmSync(j.infoFile, { force: true }); j.infoFile = null; }
  pause(id) { const j = this.state.jobs.find(j => j.id === id); if (!j || !ACTIVE.has(j.state)) return; this.mutate(j, { state: 'paused', detail: '已暂停 · 点击继续' }); if (this.active?.id === id) { this.active.cancel = true; this.active.command?.stop(); } }
  start(id) { const j = this.state.jobs.find(j => j.id === id); if (!j || !['ready', 'paused', 'failed'].includes(j.state)) return; this.dropInfo(j); this.mutate(j, { state: 'pending', error: '', refreshed: false }); void this.pump(); }
  remove(id) { const j = this.state.jobs.find(j => j.id === id); if (!j) return; this.pause(id); this.dropInfo(j); this.state.jobs = this.state.jobs.filter(x => x !== j); this.changed(); }
  async checkVersion() { const r = await this.runner(this.executable, ['--version'], { timeout: 30000 }).promise; this.engineVersion = r.code === 0 ? r.stdout.trim() : '不可用'; this.emit('state', this.snapshot()); }
  async updateEngine() {
    if (this.active || this.updating) { this.toast('请先暂停或等待当前任务完成'); return; }
    this.updating = true; this.changed();
    try {
      const dir = path.join(this.support, 'tools'); fs.mkdirSync(dir, { recursive: true }); const target = path.join(dir, path.basename(this.tool('yt-dlp')));
      if (!fs.existsSync(target)) fs.copyFileSync(this.tool('yt-dlp'), target);
      fs.chmodSync(target, 0o755);
      const r = await this.runner(target, ['--ignore-config', '-U'], { timeout: 180000 }).promise;
      if (r.code !== 0) throw Error(r.stderr); this.toast('解析器已更新'); await this.checkVersion();
    } catch (e) { this.toast('更新失败：' + safeLog(e.message)); }
    finally { this.updating = false; this.changed(); void this.pump(); }
  }
  close() { this.closed = true; for (const j of this.state.jobs) if (ACTIVE.has(j.state)) { j.state = 'paused'; j.detail = '任务已暂停，可继续'; } if (this.active) { this.active.cancel = true; this.active.command?.stop(); } this.changed(); }
}
module.exports = { DownloadLibrary, runTool, urls, platform, webURL, safeLog, within, PLATFORMS };
