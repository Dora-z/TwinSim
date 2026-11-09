// Renders promo/index.html frame by frame with headless Chrome (DevTools protocol)
// and pipes the frames into ffmpeg. Usage: node promo/render.mjs [out.mp4] [fps]
import { spawn } from 'node:child_process';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const out = process.argv[2] || path.join(here, 'build', 'video.mp4');
const fps = Number(process.argv[3] || 30);
const only = process.env.FRAMES_AT; // e.g. "2,8,15" → write PNG stills instead of a video
const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const PORT = 9300 + Math.floor(Math.random() * 500);

const chrome = spawn(CHROME, [
  '--headless=new', `--remote-debugging-port=${PORT}`, '--window-size=1920,1080',
  '--hide-scrollbars', '--force-device-scale-factor=1', '--allow-file-access-from-files',
  `--user-data-dir=${mkdtempSync(path.join(process.env.TMPDIR || tmpdir(), 'promo-chrome-'))}`,
  'about:blank',
], { stdio: 'ignore' });

const sleep = ms => new Promise(r => setTimeout(r, ms));
let target;
for (let i = 0; i < 100 && !target; i++) {
  try { target = (await (await fetch(`http://127.0.0.1:${PORT}/json`)).json()).find(t => t.type === 'page'); }
  catch { await sleep(100); }
}
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let seq = 0; const pending = new Map();
ws.addEventListener('message', ev => {
  const m = JSON.parse(ev.data);
  if (m.id && pending.has(m.id)) { const { res, rej } = pending.get(m.id); pending.delete(m.id); m.error ? rej(new Error(m.error.message)) : res(m.result); }
});
const send = (method, params = {}) => new Promise((res, rej) => { const id = ++seq; pending.set(id, { res, rej }); ws.send(JSON.stringify({ id, method, params })); });
const evaluate = async expr => (await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true })).result.value;

await send('Emulation.setDeviceMetricsOverride', { width: 1920, height: 1080, deviceScaleFactor: 1, mobile: false });
await send('Page.enable');
await send('Page.navigate', { url: pathToFileURL(path.join(here, 'index.html')).href + '?capture' });
for (let i = 0; i < 100; i++) { if (await evaluate('document.readyState') === 'complete') break; await sleep(100); }
await evaluate('document.fonts.ready.then(() => Promise.all([...document.images].map(i => i.decode().catch(() => {})))).then(() => 1)');
const duration = await evaluate('window.DURATION');

const frame = async t => {
  await evaluate(`render(${t}); new Promise(r => requestAnimationFrame(() => requestAnimationFrame(() => r(1))))`);
  return Buffer.from((await send('Page.captureScreenshot', { format: only ? 'png' : 'jpeg', quality: only ? undefined : 94 })).data, 'base64');
};

if (only) {
  const { writeFileSync, mkdirSync } = await import('node:fs');
  mkdirSync(path.dirname(out), { recursive: true });
  for (const t of only.split(',').map(Number)) writeFileSync(`${out}-${String(t).padStart(5, '0')}.png`, await frame(t));
} else {
  const total = Math.round(duration * fps);
  const ff = spawn('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', String(fps), '-c:v', 'mjpeg', '-i', '-',
    '-c:v', 'libx264', '-preset', 'slow', '-crf', '17', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', out], { stdio: ['pipe', 'inherit', 'inherit'] });
  const started = Date.now();
  for (let i = 0; i < total; i++) {
    const buf = await frame(i / fps);
    if (!ff.stdin.write(buf)) await new Promise(r => ff.stdin.once('drain', r));
    if (i % 150 === 0) console.log(`frame ${i}/${total}  ${((Date.now() - started) / 1000).toFixed(0)}s`);
  }
  ff.stdin.end();
  await new Promise(r => ff.on('close', r));
  console.log('wrote', out);
}
ws.close(); chrome.kill();
