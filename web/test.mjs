// Drives the web demo in Chromium: serves DIR (default .zig-out/web),
// waits for the shell, opens psql with `minipg app.pgdb`, makes a table,
// and checks `minipg status`. Exits nonzero on failure.
//   node web/test.mjs [DIR] [SCREENSHOT]
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { chromium } from 'playwright';

const dir = path.resolve(process.argv[2] ?? '.zig-out/web');
const shot = process.argv[3];
const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.wasm': 'application/wasm' };
const server = http.createServer((req, res) => {
  let p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  if (p.endsWith('/')) p += 'index.html';
  const f = path.join(dir, p);
  if (!f.startsWith(dir) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { 'content-type': types[path.extname(f)] ?? 'application/octet-stream', 'content-length': fs.statSync(f).size });
  fs.createReadStream(f).pipe(res);
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const url = `http://127.0.0.1:${server.address().port}/`;

const browser = await chromium.launch();
let ok = false;
try {
  const p = await browser.newPage({ viewport: { width: 1000, height: 700 } });
  p.on('pageerror', (e) => console.log('pageerror:', e.message));
  await p.goto(url);
  const text = () => p.evaluate(() => document.querySelector('.xterm-rows')?.innerText ?? '');
  const until = async (re, ms) => {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      if (re.test(await text())) return;
      await p.waitForTimeout(500);
    }
    throw new Error(`timed out waiting for ${re}; the terminal shows:\n${await text()}`);
  };
  const type = async (s) => { await p.keyboard.type(s, { delay: 5 }); await p.keyboard.press('Enter'); };
  const t0 = Date.now();
  const prompt = /~ #\s*$/m;
  await until(prompt, 180000);
  console.log(`shell after ${(Date.now() - t0) / 1000}s`);
  await type('minipg app.pgdb');
  await until(/app=#/, 180000);
  console.log(`psql after ${(Date.now() - t0) / 1000}s`);
  await type("create table notes(body text); insert into notes values ('hello'); select * from notes;");
  await until(/\(1 row\)/, 60000);
  await type('\\q');
  await until(prompt, 60000);
  await type('minipg status app.pgdb');
  await until(/app\.pgdb: running/, 60000);
  if (shot) await p.screenshot({ path: shot });
  ok = true;
} catch (e) {
  console.log(e.message);
} finally {
  await browser.close();
  server.close();
}
console.log(ok ? 'web demo: ok' : 'web demo: FAILED');
process.exit(ok ? 0 : 1);
