'use strict';
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const assert = require('node:assert/strict');
const { runTool, DownloadLibrary } = require('./core.cjs');
async function until(check, label, timeout = 60000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) { const result = await check(); if (result) return result; await new Promise(r => setTimeout(r, 100)); }
  throw Error('等待超时：' + label);
}
async function run({ mainWindow, library, tools, root }) {
  assert(root, 'VIDTUCK_SMOKE_DIR is required'); fs.mkdirSync(root, { recursive: true });
  const bin = name => path.join(tools, name + (process.platform === 'win32' ? '.exe' : ''));
  const reports = [];
  const commands = [];
  const originalRunner = library.runner;
  library.runner = (...args) => {
    const command = originalRunner(...args);
    return { ...command, promise: command.promise.then(result => { commands.push({ args: args[1], ...result }); return result; }) };
  };
  for (const name of ['yt-dlp', 'ffmpeg', 'ffprobe', 'deno']) {
    const r = await runTool(bin(name), [name === 'ffmpeg' || name === 'ffprobe' ? '-version' : '--version'], { timeout: 30000 }).promise;
    assert.equal(r.code, 0, name + ': ' + r.stderr); reports.push({ tool: name, version: r.stdout.split(/\r?\n/)[0] });
  }
  const sample = path.join(root, 'sample.mp4');
  let r = await runTool(bin('ffmpeg'), ['-y', '-f', 'lavfi', '-i', 'color=c=blue:s=64x64:r=10', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=44100', '-t', '2', '-c:v', 'mpeg4', '-c:a', 'aac', '-pix_fmt', 'yuv420p', sample], { timeout: 30000 }).promise;
  assert.equal(r.code, 0, 'generate fixture: ' + r.stderr);
  const media = fs.readFileSync(sample);
  const server = http.createServer((req, res) => {
    if (req.url.startsWith('/sample.mp4')) {
      const range = /^bytes=(\d+)-(\d*)/.exec(req.headers.range || ''), start = range ? Number(range[1]) : 0, end = range?.[2] ? Math.min(Number(range[2]), media.length - 1) : media.length - 1;
      res.writeHead(range ? 206 : 200, { 'Content-Type': 'video/mp4', 'Content-Length': end - start + 1, 'Accept-Ranges': 'bytes', ...(range ? { 'Content-Range': `bytes ${start}-${end}/${media.length}` } : {}) }); res.end(media.subarray(start, end + 1));
    } else if (req.url === '/page') { res.writeHead(200, { 'Content-Type': 'text/html' }); res.end('<title>VidTuck Windows 验收片段</title><video controls src="/sample.mp4"></video>'); }
    else { res.writeHead(404); res.end('not found'); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    const url = `http://127.0.0.1:${server.address().port}/page`;
    // Exercise renderer -> contextBridge -> validated main-process IPC -> real tools.
    await mainWindow.webContents.executeJavaScript(`window.vidtuck.send({action:'add',text:${JSON.stringify(url)}})`);
    const video = await until(() => library.state.jobs.find(j => j.state === 'done') || (library.state.jobs.find(j => j.state === 'failed') && Promise.reject(Error(library.state.jobs.find(j => j.state === 'failed').error))), 'video download');
    assert(fs.existsSync(video.file));
    r = await runTool(bin('ffprobe'), ['-v', 'error', '-show_entries', 'stream=codec_type', '-of', 'json', video.file]).promise;
    assert.equal(r.code, 0, r.stderr); const streams = JSON.parse(r.stdout).streams;
    assert(streams.some(s => s.codec_type === 'video')); assert(streams.some(s => s.codec_type === 'audio'));
    reports.push({ check: 'renderer IPC -> video download -> ffprobe audio/video validation', passed: true, size: fs.statSync(video.file).size });
    library.state.mode = 'audio'; library.add(url);
    const audio = await until(() => library.state.jobs.find(j => j.mode === 'audio' && j.state === 'done') || (library.state.jobs.find(j => j.mode === 'audio' && j.state === 'failed') && Promise.reject(Error(library.state.jobs.find(j => j.mode === 'audio' && j.state === 'failed').error))), 'M4A export');
    assert.equal(path.extname(audio.file), '.m4a');
    r = await runTool(bin('ffprobe'), ['-v', 'error', '-show_entries', 'stream=codec_type', '-of', 'json', audio.file]).promise;
    assert.equal(r.code, 0, r.stderr); assert(JSON.parse(r.stdout).streams.every(s => s.codec_type === 'audio'));
    reports.push({ check: 'M4A export and audio-only validation', passed: true });
    const reloaded = new DownloadLibrary({ support: library.support, tools, destination: library.state.destination }); assert.equal(reloaded.state.jobs.filter(j => j.state === 'done').length, 2);
    reports.push({ check: 'history reload', passed: true });
    await until(async () => (await mainWindow.webContents.executeJavaScript('document.querySelectorAll("article.done").length')) === 2, 'render completed tasks');
    assert.equal(await mainWindow.webContents.executeJavaScript('typeof require'), 'undefined');
    reports.push({ check: 'sandbox renderer and completed task UI', passed: true });
    fs.writeFileSync(path.join(root, 'window.png'), (await mainWindow.webContents.capturePage()).toPNG());
    library.remove(video.id); assert(fs.existsSync(video.file), 'Removing a job must retain the downloaded media');
    reports.push({ check: 'remove record retains original media', passed: true });
    fs.writeFileSync(path.join(root, 'report.json'), JSON.stringify({ platform: process.platform, arch: process.arch, packaged: process.resourcesPath.includes('resources'), reports }, null, 2));
  } catch (error) {
    error.message += '\n' + JSON.stringify({ commands, jobs: library.state.jobs, files: fs.readdirSync(library.state.destination) }, null, 2);
    throw error;
  } finally { library.runner = originalRunner; server.close(); }
}
module.exports = { run };
