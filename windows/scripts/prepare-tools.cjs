'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
const tools = path.join(root, 'tools'), licenses = path.join(root, 'licenses'), cache = path.join(root, '.cache');
for (const dir of [tools, licenses, cache]) fs.mkdirSync(dir, { recursive: true });
const files = [
  { name: 'yt-dlp.exe', url: 'https://github.com/yt-dlp/yt-dlp/releases/download/2026.10.21/yt-dlp.exe', sha256: '33121d192d706e62f684a06f80918e3f3a8ba52ac3a65213b6951c39c7d9f555' },
  { name: 'deno.zip', url: 'https://github.com/denoland/deno/releases/download/v2.9.8/deno-x86_64-pc-windows-msvc.zip', sha256: 'cba84b26e0df5ae7f74fc66b86a95b866872a86292ebd84fa1e959927edd93bf' },
  { name: 'ffmpeg.zip', url: 'https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-10-23-13-04/ffmpeg-n8.1.3-24-g92611900bb-win64-lgpl-shared-8.1.zip', sha256: 'e7827a3897d0914b538c14efb8dc2d88020a4fd2b593bad3dbd668a691d076ad' }
];
async function download(url, target, expected) {
  if (fs.existsSync(target) && (!expected || sha(target) === expected)) return;
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      console.log('获取 ' + path.basename(target));
      const response = await fetch(url, { signal: AbortSignal.timeout(240000) });
      if (!response.ok) throw Error(`下载失败 HTTP ${response.status}`);
      const file = fs.openSync(target + '.tmp', 'w');
      try { for await (const part of response.body) fs.writeSync(file, part); } finally { fs.closeSync(file); }
      if (expected && sha(target + '.tmp') !== expected) throw Error('SHA-256 校验失败：' + target);
      fs.renameSync(target + '.tmp', target); return;
    } catch (e) { if (attempt === 3) throw e; }
  }
}
function sha(file) { return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex'); }
function extract(file, dir) {
  const seven = require('7zip-bin').path7za;
  if (process.platform !== 'win32') fs.chmodSync(seven, 0o755);
  const r = spawnSync(seven, ['x', '-y', '-o' + dir, file], { stdio: 'pipe' });
  if (r.status !== 0) throw Error('解压失败：' + String(r.stderr || r.error));
}
async function main() {
  await Promise.all(files.map(f => download(f.url, path.join(cache, f.name), f.sha256)));
  fs.copyFileSync(path.join(cache, 'yt-dlp.exe'), path.join(tools, 'yt-dlp.exe'));
  extract(path.join(cache, 'deno.zip'), path.join(cache, 'deno'));
  fs.copyFileSync(path.join(cache, 'deno', 'deno.exe'), path.join(tools, 'deno.exe'));
  const ffdir = path.join(cache, 'ffmpeg'); extract(path.join(cache, 'ffmpeg.zip'), ffdir);
  const ffroot = path.join(ffdir, fs.readdirSync(ffdir).find(n => n.startsWith('ffmpeg-')));
  for (const name of fs.readdirSync(path.join(ffroot, 'bin'))) if (name.endsWith('.dll') || ['ffmpeg.exe', 'ffprobe.exe'].includes(name)) fs.copyFileSync(path.join(ffroot, 'bin', name), path.join(tools, name));
  fs.copyFileSync(path.join(ffroot, 'LICENSE.txt'), path.join(licenses, 'FFmpeg-LGPL-3.0.txt'));
  // Include the exact FFmpeg source revision and the distributor's build scripts/patches.
  await Promise.all([
    download('https://github.com/FFmpeg/FFmpeg/archive/92611900bb.tar.gz', path.join(licenses, 'ffmpeg-92611900bb-source.tar.gz')),
    download('https://github.com/BtbN/FFmpeg-Builds/archive/refs/tags/autobuild-2026-10-23-13-04.tar.gz', path.join(licenses, 'ffmpeg-build-scripts.tar.gz')),
    download('https://raw.githubusercontent.com/yt-dlp/yt-dlp/2026.10.21/THIRD_PARTY_LICENSES.txt', path.join(licenses, 'yt-dlp-THIRD_PARTY_LICENSES.txt'))
  ]);
  for (const name of ['yt-dlp-LICENSE.txt', 'deno-LICENSE.md', 'V8-LICENSE.txt', 'V8-BSD-LICENSE.txt']) fs.copyFileSync(path.join(root, '..', 'ThirdParty', name), path.join(licenses, name));
  fs.writeFileSync(path.join(licenses, 'SOURCES.json'), JSON.stringify({ binaries: files, ffmpegSource: 'https://github.com/FFmpeg/FFmpeg/tree/92611900bb', ffmpegBuild: 'https://github.com/BtbN/FFmpeg-Builds/tree/autobuild-2026-10-23-13-04', dependencySources: 'See scripts.d in ffmpeg-build-scripts.tar.gz for each dependency source and build options. Shared libav DLLs remain replaceable.', ytDlpSource: 'https://github.com/yt-dlp/yt-dlp/tree/2026.10.21', denoSource: 'https://github.com/denoland/deno/tree/v2.9.8' }, null, 2));
  fs.writeFileSync(path.join(tools, 'SHA256SUMS.txt'), fs.readdirSync(tools).filter(n => /\.(exe|dll)$/.test(n)).sort().map(n => `${sha(path.join(tools, n))}  ${n}`).join('\n') + '\n');
  console.log('Windows 组件已准备并通过 SHA-256 校验');
}
main().catch(e => { console.error(e.message); process.exitCode = 1; });
