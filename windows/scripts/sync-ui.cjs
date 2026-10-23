'use strict';
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
fs.mkdirSync(path.join(root, 'ui'), { recursive: true });
for (const name of ['index.html', 'app.css', 'app.js', 'AppIcon.png']) {
  let data = fs.readFileSync(path.join(root, '..', 'Resources', name));
  if (name.endsWith('.html') || name.endsWith('.js')) {
    data = data.toString().replaceAll('⌘', 'Ctrl+').replaceAll('0.2.6', require('../package.json').version);
    if (name === 'app.js') {
      data = data.replace("window.webkit?.messageHandlers?.native?.postMessage({action,...data})", "window.vidtuck.send({action,...data})");
      data += '\nwindow.vidtuck.onMessage(message => window.receive(message));\n';
    }
  }
  fs.writeFileSync(path.join(root, 'ui', name), data);
}
