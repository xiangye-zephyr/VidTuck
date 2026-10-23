'use strict';
const { platform, webURL } = require('./core.cjs');
const mobileAgent = 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
function videoID(value) { const u = webURL(value); return u && platform(value) === '抖音' ? u.pathname.match(/\/(?:share\/)?video\/(\d+)/)?.[1] || (/^\d+$/.test(u.searchParams.get('modal_id') || '') ? u.searchParams.get('modal_id') : null) : null; }
function metadata(value, id, page) {
  function find(node, depth = 0) {
    if (!node || typeof node !== 'object' || depth > 14) return;
    if (String(node.aweme_id || node.awemeId || node.id || '') === id && node.video) return node;
    for (const child of Object.values(node).slice(0, 200)) { const found = find(child, depth + 1); if (found) return found; }
  }
  const item = find(value); if (!item) return null;
  const video = item.video, formats = [], seen = new Set();
  const addresses = v => typeof v === 'string' ? [v] : v?.url_list || v?.urlList || (v?.url ? [v.url] : []);
  const add = (value, parent = {}) => {
    const group = `stream-${formats.length}`;
    addresses(value).forEach((url, i) => {
      if (!webURL(url) || seen.has(url)) return; seen.add(url);
      formats.push({ format_id: 'direct-' + formats.length, url, ext: 'mp4', width: Number(value?.width || parent.width || video.width) || undefined, height: Number(value?.height || parent.height || video.height) || undefined, filesize: Number(value?.data_size || value?.dataSize) || undefined, tbr: Number(parent.bit_rate || parent.bitRate) / 1000 || undefined, vcodec: parent.is_h265 || parent.isH265 ? 'hevc' : 'h264', source_preference: /\/aweme\/v1\/play/.test(new URL(url).pathname) ? -100 : -i, vidtuck_mirror_group: group, http_headers: { Referer: page, 'User-Agent': mobileAgent } });
    });
  };
  for (const rate of video.bit_rate || video.bitRateList || []) add(rate.play_addr || rate.playAddr, rate);
  for (const key of ['play_addr', 'playAddr', 'play_addr_h264', 'playAddrH264', 'play_addr_265', 'playAddrH265']) add(video[key], video);
  if (!formats.length) return null;
  return { id, title: item.desc || item.item_title || item.itemTitle || `抖音视频 ${id}`, webpage_url: page, extractor: 'douyin-direct', extractor_key: 'Generic', duration: Number(video.duration || 0) / 1000, thumbnail: ['cover', 'origin_cover', 'originCover', 'dynamic_cover', 'dynamicCover'].flatMap(k => addresses(video[k])).find(webURL) || '', formats };
}
function pageMetadata(text, id, page) {
  try { const info = metadata(JSON.parse(text), id, page); if (info) return info; } catch {}
  for (const pattern of [/window\._ROUTER_DATA\s*=\s*([\s\S]*?)<\/script>/g, /<script[^>]*\bid=["']RENDER_DATA["'][^>]*>([\s\S]*?)<\/script>/g]) {
    for (const match of text.matchAll(pattern)) {
      const raw = match[1].trim().replace(/;$/, '');
      for (let candidate of [raw]) { try { candidate = decodeURIComponent(candidate); } catch {} try { const info = metadata(JSON.parse(candidate), id, page); if (info) return info; } catch {} }
    }
  }
  return null;
}
async function resolveDirect(url, session, token) {
  let id = videoID(url);
  const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 8000);
  try {
    let target = id ? `https://www.iesdouyin.com/share/video/${id}/` : url;
    for (let redirects = 0; redirects < 6; redirects++) {
      if (token.cancel || platform(target) !== '抖音') return null;
      const response = await session.fetch(target, { signal: controller.signal, redirect: 'manual', headers: { 'User-Agent': mobileAgent, Referer: 'https://www.douyin.com/' } });
      id ||= videoID(target);
      if (response.status >= 300 && response.status < 400 && response.headers.get('location')) { target = new URL(response.headers.get('location'), target).href; continue; }
      const text = await response.text(); if (text.length > 8000000 || !id) return null;
      return pageMetadata(text, id, `https://www.douyin.com/video/${id}`);
    }
  } catch {} finally { clearTimeout(timer); }
  return null;
}
module.exports = { videoID, metadata, pageMetadata, resolveDirect };
