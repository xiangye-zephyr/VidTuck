'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { DownloadLibrary, urls, platform, safeLog } = require('../src/core.cjs');
const { metadata, pageMetadata } = require('../src/douyin.cjs');
const wait = async predicate => { for (let n = 0; n < 300; n++) { if (predicate()) return; await new Promise(r => setTimeout(r, 5)); } throw Error('timeout'); };
function create(t, runner) { const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'vidtuck-')); t.after(() => fs.rmSync(dir, { recursive: true, force: true })); return new DownloadLibrary({ support: path.join(dir, 'state'), tools: path.join(dir, 'tools with spaces'), destination: path.join(dir, '视频 下载'), runner }); }
test('share text preserves signed parameters and rejects credentials / lookalike domains', () => {
  assert.deepEqual(urls('视频 https://www.xiaohongshu.com/explore/ab?xsec_token=a%2Bb&x=1。 https://www.xiaohongshu.com/explore/ab?xsec_token=a%2Bb&x=1'), ['https://www.xiaohongshu.com/explore/ab?xsec_token=a%2Bb&x=1']);
  assert.deepEqual(urls('https://user:secret@example.com/x'), []);
  assert.equal(platform('https://youtube.com.attacker.test/x'), '其他');
  assert.equal(platform('https://www.bilibili.com/video/BV123'), 'B站');
  assert(!safeLog('https://example.com/?token=abc Cookie=secret').includes('secret'));
});
test('pause while analysis exits does not revive a paused job; FIFO queue continues', async t => {
  let settle, calls = 0;
  const l = create(t, () => { calls++; return { stop() { settle({ code: -1, stdout: '', stderr: 'stopped' }); }, promise: new Promise(r => { settle = r; }) }; });
  l.add('https://example.com/one'); const first = l.state.jobs[0]; l.add('https://example.com/two');
  assert.equal(calls, 1); l.pause(first.id);
  await wait(() => calls === 2); assert.equal(first.state, 'paused'); l.close();
});
test('expired cached download retries once by extracting the original page', async t => {
  let extracts = 0, downloads = 0;
  const l = create(t, (_exe, args) => {
    const extracting = args.includes('--dump-single-json'); if (extracting) extracts++; else downloads++;
    return { stop() {}, promise: Promise.resolve(extracting ? { code: 0, stdout: JSON.stringify({ id: 'a', title: 'fixture', formats: [{ url: 'https://cdn.test/a', height: 720, ext: 'mp4' }] }), stderr: '' } : { code: 1, stdout: '', stderr: 'expired media' }) };
  });
  l.add('https://example.com/video'); await wait(() => l.state.jobs[0].state === 'failed');
  assert.equal(extracts, 2); assert.equal(downloads, 2); l.close();
});
test('crash recovery pauses unfinished records; corrupt history is backed up', t => {
  const l = create(t, () => {}); l.state.jobs = [{ id: 'a', state: 'downloading', infoFile: 'bad' }]; l.changed();
  const options = { support: l.support, tools: l.tools, destination: l.state.destination };
  const restored = new DownloadLibrary(options); assert.equal(restored.state.jobs[0].state, 'paused'); assert.equal(restored.state.jobs[0].infoFile, null);
  fs.writeFileSync(path.join(l.support, 'library.json'), '{broken');
  const recovered = new DownloadLibrary(options); assert.equal(recovered.state.jobs.length, 0); assert(fs.readdirSync(l.support).some(n => n.startsWith('library.json.unreadable-')));
});
test('Douyin metadata must match requested ID and exclude cover/download addresses', () => {
  const fixture = { aweme_id: '12345', desc: 'fixture', video: { width: 1920, height: 1080, play_addr: { url_list: ['https://cdn.example.com/one', 'https://cdn.example.com/two'], data_size: 100 }, cover: { url_list: ['https://cdn.example.com/cover.jpg'] }, download_addr: { url_list: ['https://cdn.example.com/watermark'] } } };
  assert.equal(metadata(fixture, '98765', 'https://www.douyin.com/video/98765'), null);
  const info = metadata(fixture, '12345', 'https://www.douyin.com/video/12345'); assert.equal(info.formats.length, 2); assert.equal(info.formats[0].vidtuck_mirror_group, info.formats[1].vidtuck_mirror_group);
  assert.equal(pageMetadata('<script>window._ROUTER_DATA = ' + JSON.stringify(fixture) + ';</script>', '12345', 'https://www.douyin.com/video/12345').title, 'fixture');
});
