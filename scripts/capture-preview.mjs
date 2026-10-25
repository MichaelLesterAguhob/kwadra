// Dependency-free visual smoke check for the release web build.
// Run from the repository root: node scripts/capture-preview.mjs
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { readFile, mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { resolve, extname, sep } from 'node:path';
import { tmpdir } from 'node:os';

const root = resolve('apps/management/build/web');
const output = resolve('artifacts/screenshots');
await mkdir(output, { recursive: true });
const mime = { '.html': 'text/html', '.js': 'text/javascript', '.json': 'application/json', '.wasm': 'application/wasm', '.png': 'image/png', '.jpg': 'image/jpeg', '.ttf': 'font/ttf' };
const server = createServer(async (req, res) => {
  try {
    const pathname = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
    const file = resolve(root, `.${pathname === '/' ? '/index.html' : pathname}`);
    if (!file.startsWith(root + sep)) { res.writeHead(403); res.end(); return; }
    const data = await readFile(file);
    res.writeHead(200, { 'Content-Type': mime[extname(file)] ?? 'application/octet-stream', 'Cache-Control': 'no-store' });
    res.end(data);
  } catch { res.writeHead(404); res.end('Not found'); }
});
await new Promise((done) => server.listen(8765, '127.0.0.1', done));
const profile = await mkdtemp(resolve(tmpdir(), 'kwadra-preview-'));
const browser = spawn(process.env.KWADRA_CHROME ?? 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe', [
  '--headless=new', '--no-first-run', '--no-default-browser-check', '--disable-background-networking',
  '--enable-unsafe-swiftshader', '--remote-debugging-port=9225', `--user-data-dir=${profile}`, 'about:blank',
], { windowsHide: true, stdio: 'ignore' });
const delay = (ms) => new Promise((done) => setTimeout(done, ms));
let socket;
const failures = [];
try {
  let targets;
  for (let attempt = 0; attempt < 80; attempt++) {
    try { targets = await (await fetch('http://127.0.0.1:9225/json')).json(); break; } catch { await delay(200); }
  }
  if (!targets) throw new Error('Chrome debugging endpoint did not open.');
  const page = targets.find((t) => t.type === 'page');
  socket = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((done, reject) => { socket.addEventListener('open', done, { once: true }); socket.addEventListener('error', reject, { once: true }); });
  let id = 0;
  const pending = new Map();
  const requests = new Map();
  socket.addEventListener('message', (event) => {
    const message = JSON.parse(event.data);
    if (message.id) {
      const task = pending.get(message.id);
      if (task) { pending.delete(message.id); message.error ? task.reject(new Error(JSON.stringify(message.error))) : task.resolve(message.result); }
    }
    if (message.method === 'Runtime.exceptionThrown') failures.push(message.params.exceptionDetails);
    if (message.method === 'Network.requestWillBeSent') requests.set(message.params.requestId, message.params.request.url);
    if (message.method === 'Network.loadingFailed') failures.push({ network: requests.get(message.params.requestId), reason: message.params.errorText });
  });
  function call(method, params = {}) {
    return new Promise((resolveCall, reject) => {
      const requestId = ++id;
      const timer = setTimeout(() => { pending.delete(requestId); reject(new Error(`Timed out: ${method}`)); }, 20000);
      pending.set(requestId, { resolve: (v) => { clearTimeout(timer); resolveCall(v); }, reject: (e) => { clearTimeout(timer); reject(e); } });
      socket.send(JSON.stringify({ id: requestId, method, params }));
    });
  }
  await call('Runtime.enable');
  await call('Network.enable');
  await call('Page.enable');
  await call('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1100, deviceScaleFactor: 1, mobile: false });
  await call('Page.navigate', { url: 'http://127.0.0.1:8765' });
  let ready = false;
  for (let attempt = 0; attempt < 100; attempt++) {
    const result = await call('Runtime.evaluate', { expression: "document.querySelector('flutter-view') !== null && document.getElementById('loading') === null", returnByValue: true });
    if (result.result.value) { ready = true; break; }
    await delay(250);
  }
  if (!ready) throw new Error('Flutter did not render its first frame.');
  await delay(1000);
  const desktop = await call('Page.captureScreenshot', { format: 'png' });
  await writeFile(resolve(output, 'desktop-overview.png'), Buffer.from(desktop.data, 'base64'));
  async function click(x, y) {
    await call('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', clickCount: 1 });
    await call('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', clickCount: 1 });
    await delay(500);
  }
  await call('Runtime.evaluate', { expression: "document.querySelector('flt-semantics-placeholder')?.click()" });
  await delay(400);
  async function clickLabel(label) {
    const tree = await call('Accessibility.getFullAXTree');
    const candidates = tree.nodes.filter((n) => ['button', 'tab', 'link'].includes(n.role?.value) && n.backendDOMNodeId);
    const node = candidates.find((n) => n.name?.value === label)
      ?? candidates.find((n) => n.name?.value?.startsWith(label))
      ?? tree.nodes.find((n) => n.backendDOMNodeId && n.name?.value?.startsWith(label));
    if (!node) throw new Error(`Could not find accessible control: ${label}`);
    await call('DOM.scrollIntoViewIfNeeded', { backendNodeId: node.backendDOMNodeId });
    const { model } = await call('DOM.getBoxModel', { backendNodeId: node.backendDOMNodeId });
    const quad = model.content;
    await click((quad[0] + quad[2] + quad[4] + quad[6]) / 4, (quad[1] + quad[3] + quad[5] + quad[7]) / 4);
  }
  await clickLabel('Properties');
  const properties = await call('Page.captureScreenshot', { format: 'png' });
  await writeFile(resolve(output, 'desktop-properties.png'), Buffer.from(properties.data, 'base64'));
  await clickLabel('More');
  await clickLabel('Repairs');
  const maintenance = await call('Page.captureScreenshot', { format: 'png' });
  await writeFile(resolve(output, 'desktop-maintenance.png'), Buffer.from(maintenance.data, 'base64'));
  await clickLabel('Home');
  await call('Runtime.evaluate', { expression: "document.querySelector('flt-semantics-placeholder')?.click()" });
  await delay(400);
  const accessibility = await call('Accessibility.getFullAXTree');
  await writeFile(resolve(output, 'accessibility.json'), JSON.stringify(accessibility, null, 2));
  await call('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
  await delay(700);
  const mobile = await call('Page.captureScreenshot', { format: 'png' });
  await writeFile(resolve(output, 'mobile-overview.png'), Buffer.from(mobile.data, 'base64'));
  const title = await call('Runtime.evaluate', { expression: 'document.title', returnByValue: true });
  const report = { title: title.result.value, firstFrame: ready, failures, screenshots: ['desktop-overview.png', 'desktop-properties.png', 'desktop-maintenance.png', 'mobile-overview.png'] };
  await writeFile(resolve(output, 'report.json'), JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report, null, 2));
  // This dedicated browser profile belongs only to this preview process.
  // Chrome can close the debugging socket before acknowledging Browser.close.
  // Send shutdown without requiring a response from a disappearing session.
  socket.send(JSON.stringify({ id: ++id, method: 'Browser.close' }));
  await Promise.race([new Promise((done) => browser.once('exit', done)), delay(1000)]);
  if (failures.length) process.exitCode = 1;
} catch (error) {
  console.error(error);
  process.exitCode = 1;
} finally {
  socket?.close();
  browser.kill();
  server.close();
}
