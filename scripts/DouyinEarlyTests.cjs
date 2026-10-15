const vm = require('node:vm');
const fs = require('node:fs');
const assert = require('node:assert/strict');
const code = fs.readFileSync(process.argv[2], 'utf8');
const id = '7669433433201986868';
const target = {aweme_id: id, video: {play_addr: {url_list: ['https://media.example/video.mp4']}}};
let response, messages = [], cloneCount = 0;
const result = Promise.resolve({clone() {cloneCount++; return {json: async () => response};}});
class XHR {
  addEventListener(name, fn) { this.listener = fn; }
  open(...args) { this.args = args; return 'original-open'; }
}
const context = {
  URL, URLSearchParams, XMLHttpRequest: XHR,
  location: {hostname: 'www.douyin.com', href: `https://www.douyin.com/video/${id}`, pathname: `/video/${id}`, search: ''},
  window: {fetch: () => result, webkit: {messageHandlers: {douyinData: {postMessage: value => messages.push(value)}}}}
};
vm.runInNewContext(code, context);
const flush = () => new Promise(resolve => setImmediate(resolve));
(async () => {
  response = {aweme_detail: target};
  assert.equal(context.window.fetch('https://www.douyin.com/aweme/v1/web/aweme/detail/'), result);
  await flush();
  assert.equal(messages.length, 1);
  assert.equal(messages[0].aweme_id, id);
  console.log('PASS: target detail response is delivered before player rendering; original fetch result is preserved');
  response = {aweme_detail: {aweme_id: '999', video: target.video}};
  context.window.fetch('https://www.douyin.com/aweme/v1/web/aweme/detail/');
  await flush();
  assert.equal(messages.length, 1);
  console.log('PASS: recommendation or unrelated video responses are ignored');
  const before = cloneCount;
  context.window.fetch('https://unrelated.example/aweme/v1/web/aweme/detail/');
  context.window.fetch('https://www.douyin.com/account/private/');
  await flush();
  assert.equal(cloneCount, before);
  console.log('PASS: unrelated hosts and non-video responses are not inspected');
  const xhr = new context.XMLHttpRequest();
  assert.equal(xhr.open('GET', 'https://www.iesdouyin.com/web/api/v2/aweme/iteminfo/'), 'original-open');
  xhr.responseType = 'json'; xhr.response = {item_list: [target]}; xhr.listener();
  assert.equal(messages.length, 2);
  console.log('PASS: share-page XHR data also resolves the exact target and preserves open behavior');
  const parsed = vm.runInNewContext(`JSON.parse(${JSON.stringify(JSON.stringify({aweme_detail:target}))})`, context);
  assert.equal(parsed.aweme_detail.aweme_id, id);
  assert.equal(messages.length, 3);
  assert.equal(vm.runInNewContext('JSON.parse(\'{"value":1}\', (key,value) => key === "value" ? value + 1 : value)', context).value, 2);
  assert.throws(() => vm.runInNewContext('JSON.parse("invalid")', context), {name:'SyntaxError'});
  vm.runInNewContext(`JSON.parse(${JSON.stringify(JSON.stringify({aweme_detail:{...target,aweme_id:'999'}}))})`, context);
  assert.equal(messages.length, 3);
  console.log('PASS: SDK JSON parsing resolves only the target while preserving return values, revivers and parse errors');
  console.log('ALL EARLY RESPONSE TESTS PASSED');
})().catch(e => { console.error(e); process.exitCode = 1; });
