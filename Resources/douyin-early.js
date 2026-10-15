// Observe only the target page's own detail response, before player rendering.
(() => {
  if (!/(^|\.)(douyin|iesdouyin)\.com$/.test(location.hostname)) return;
  const targetID = () => location.pathname.match(/\/(?:share\/)?video\/(\d+)/)?.[1] || new URLSearchParams(location.search).get('modal_id');
  const inspect = value => {
    const id = targetID();
    if (!id) return;
    const seen = new WeakSet();
    const find = (node, depth = 0) => {
      if (!node || typeof node !== 'object' || depth > 12 || seen.has(node)) return;
      seen.add(node);
      if (String(node.aweme_id || node.awemeId || node.id || '') === id && node.video) return node;
      for (const child of Object.values(node).slice(0, 200)) {
        const found = find(child, depth + 1);
        if (found) return found;
      }
    };
    const video = find(value);
    if (video) {
      window.__streamNestVideo = video;
      window.webkit?.messageHandlers?.douyinData?.postMessage(video);
    }
  };
  // Some site SDKs decode responses after fetch/XHR. Observe that parse without
  // depending on a particular endpoint or waiting for the player to render.
  const originalParse = JSON.parse;
  JSON.parse = function (...args) {
    const result = Reflect.apply(originalParse, this, args);
    const text = args[0], id = targetID();
    if (id && typeof text === 'string' && text.length < 8000000 && text.includes(id) && text.includes('video')) { try { inspect(result); } catch {} }
    return result;
  };
  const isDetail = url => {
    try {
      const u = new URL(String(url), location.href);
      return /(^|\.)(douyin|iesdouyin)\.com$/.test(u.hostname) && /(?:\/aweme\/v1\/web\/aweme\/detail\/|\/web\/api\/v2\/aweme\/iteminfo\/)/.test(u.pathname);
    } catch { return false; }
  };
  const originalFetch = window.fetch;
  window.fetch = function (...args) {
    const result = Reflect.apply(originalFetch, this, args);
    if (isDetail(args[0]?.url || args[0])) result.then(r => r.clone().json()).then(inspect).catch(() => {});
    return result;
  };
  const originalOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (...args) {
    if (isDetail(args[1])) this.addEventListener('load', () => {
      try { inspect(this.responseType === 'json' ? this.response : JSON.parse(this.responseText)); } catch {}
    }, { once: true });
    return Reflect.apply(originalOpen, this, args);
  };
})();
