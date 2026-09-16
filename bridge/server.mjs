import http from 'node:http';
import https from 'node:https';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { mkdir, readFile, writeFile, chmod } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { randomBytes, timingSafeEqual, X509Certificate } from 'node:crypto';
import { WebSocketServer, WebSocket } from 'ws';
import QRCode from 'qrcode';
import { CodexClient } from './codex.mjs';
import { PhoneSession } from './session.mjs';

export function authorized(header, token) {
  const actual = Buffer.from(typeof header === 'string' ? header : '');
  const expected = Buffer.from(`Bearer ${token}`);
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}
const root = path.dirname(fileURLToPath(import.meta.url));

export async function startBridge({ dataDir = process.env.RAYBRIDGE_DATA_DIR || path.join(os.homedir(), 'Library/Application Support/RayBridge'),
  adminPort = 8844, phonePort = 8845, codex: suppliedCodex } = {}) {
  await mkdir(dataDir, { recursive: true, mode: 0o700 });
  await chmod(dataDir, 0o700);
  const certPath = path.join(dataDir, 'server.crt');
  const keyPath = path.join(dataDir, 'server.key');
  let cert, key;
  try { cert = await readFile(certPath); key = await readFile(keyPath); }
  catch {
    execFileSync('/usr/bin/openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes',
      '-keyout', keyPath, '-out', certPath, '-days', '3650', '-subj', '/CN=RayBridge Local Bridge'], { stdio: 'ignore' });
    await chmod(keyPath, 0o600);
    cert = await readFile(certPath); key = await readFile(keyPath);
  }
  const fingerprint = new X509Certificate(cert).fingerprint256.replaceAll(':', '').toLowerCase();
  const tokenPath = path.join(dataDir, 'phone-token');
  let token;
  try { token = (await readFile(tokenPath, 'utf8')).trim(); } catch { token = randomBytes(32).toString('hex'); }
  if (!/^[a-f0-9]{64}$/.test(token)) token = randomBytes(32).toString('hex');
  await writeFile(tokenPath, token, { mode: 0o600 });
  const codex = suppliedCodex || new CodexClient(path.join(dataDir, 'codex'));
  let serviceError = null;
  codex.on('unavailable', error => { serviceError = error.message; for (const socket of wss.clients) socket.close(1011, 'ChatGPT connection stopped'); });
  const wss = new WebSocketServer({ noServer: true, maxPayload: 700_000, perMessageDeflate: false });
  try { await codex.start(); } catch (error) { serviceError = error.message; }
  const phones = new Map();
  const sendJSON = (res, status, data) => {
    res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    res.end(JSON.stringify(data));
  };
  const phone = https.createServer({ key, cert, minVersion: 'TLSv1.2' }, (req, res) => {
    sendJSON(res, authorized(req.headers.authorization, token) ? 404 : 401, { error: 'Use the paired iPhone app.' });
  });
  phone.on('upgrade', (req, socket, head) => {
    if (req.url !== '/v1/connect' || req.headers.origin || !authorized(req.headers.authorization, token)) {
      socket.end('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n'); return;
    }
    if (serviceError || wss.clients.size >= 1) {
      socket.end('HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n'); return;
    }
    wss.handleUpgrade(req, socket, head, ws => wss.emit('connection', ws));
  });
  wss.on('connection', ws => {
    const send = value => { if (ws.readyState === WebSocket.OPEN) {
      if (ws.bufferedAmount > 1_000_000) ws.close(1013, 'Connection too slow');
      else ws.send(JSON.stringify(value));
    } };
    const session = new PhoneSession(codex, send);
    phones.set(ws, session);
    ws.alive = true;
    ws.on('pong', () => { ws.alive = true; });
    let windowStart = Date.now(), count = 0;
    ws.on('message', async (data, binary) => {
      if (Date.now() - windowStart > 1000) { windowStart = Date.now(); count = 0; }
      if (++count > 12) { ws.close(1008, 'Too many messages'); return; }
      try {
        if (binary) throw new Error('Expected a JSON message.');
        const message = JSON.parse(data.toString());
        if (!message || typeof message !== 'object') throw new Error('Invalid message.');
        await session.receive(message);
      } catch (error) { send({ type: 'error', message: error.message }); }
    });
    ws.on('error', () => ws.terminate());
    ws.on('close', () => { session.close(); phones.delete(ws); });
    send({ type: 'ready' });
  });
  const heartbeat = setInterval(() => {
    for (const ws of wss.clients) {
      if (!ws.alive) { ws.terminate(); continue; }
      ws.alive = false; ws.ping();
    }
  }, 15000);
  let loginPending = false;
  codex.on('notification', message => { if (message.method === 'account/login/completed') loginPending = false; });
  const admin = http.createServer(async (req, res) => {
    // Loopback bind plus strict Host and same-origin checks prevent LAN access and DNS rebinding.
    const host = req.headers.host;
    const ownOrigin = `http://127.0.0.1:${admin.address()?.port || adminPort}`;
    if (host !== `127.0.0.1:${admin.address()?.port || adminPort}` ||
      (req.headers.origin && req.headers.origin !== ownOrigin)) return sendJSON(res, 403, { error: 'Local access only.' });
    if (req.method === 'POST' && req.headers['x-raybridge'] !== 'local') return sendJSON(res, 403, { error: 'Invalid local request.' });
    try {
      if (req.method === 'GET' && req.url === '/api/status') {
        const account = serviceError ? { signedIn: false } : await codex.account();
        const hosts = Object.values(os.networkInterfaces()).flat().filter(x => x && x.family === 'IPv4' && !x.internal).map(x => x.address);
        return sendJSON(res, 200, { ...account, error: serviceError, phoneConnected: wss.clients.size > 0, hosts, phonePort: phone.address().port, loginPending });
      }
      if (req.method === 'GET' && req.url?.startsWith('/api/pair?')) {
        const hostIP = new URL(req.url, ownOrigin).searchParams.get('host');
        const addresses = Object.values(os.networkInterfaces()).flat().filter(Boolean).map(x => x.address);
        if (!addresses.includes(hostIP)) throw new Error('Choose a local network address.');
        const link = `raybridge://pair?${new URLSearchParams({ host: hostIP, port: String(phone.address().port), token, fingerprint })}`;
        return sendJSON(res, 200, { link, qr: await QRCode.toDataURL(link, { width: 320, margin: 2 }) });
      }
      if (req.method === 'POST' && req.url === '/api/login') {
        if (loginPending) throw new Error('Sign-in is already open. Finish it in your browser.');
        const login = await codex.call('account/login/start', { type: 'chatgpt' });
        loginPending = true;
        return sendJSON(res, 200, { url: login.authUrl });
      }
      if (req.method === 'POST' && req.url === '/api/logout') {
        for (const ws of wss.clients) ws.close(1000, 'Signed out on Mac');
        await codex.call('account/logout'); loginPending = false;
        return sendJSON(res, 200, { ok: true });
      }
      if (req.method === 'POST' && req.url === '/api/revoke') {
        token = randomBytes(32).toString('hex');
        await writeFile(tokenPath, token, { mode: 0o600 });
        for (const ws of wss.clients) ws.close(1000, 'Pairing revoked');
        return sendJSON(res, 200, { ok: true });
      }
      const files = { '/': ['index.html', 'text/html'], '/app.js': ['app.js', 'text/javascript'], '/style.css': ['style.css', 'text/css'] };
      if (req.method === 'GET' && files[req.url]) {
        const [name, type] = files[req.url];
        res.writeHead(200, { 'Content-Type': type, 'Cache-Control': 'no-store',
          'Content-Security-Policy': "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; frame-ancestors 'none'", 'X-Content-Type-Options': 'nosniff' });
        return res.end(await readFile(path.join(root, 'public', name)));
      }
      sendJSON(res, 404, { error: 'Not found' });
    } catch (error) { sendJSON(res, 400, { error: error.message }); }
  });
  const listen = (server, port, host) => new Promise((resolve, reject) => {
    server.once('error', reject); server.listen(port, host, resolve);
  });
  try { await listen(phone, phonePort, '0.0.0.0'); await listen(admin, adminPort, '127.0.0.1'); }
  catch (error) { clearInterval(heartbeat); phone.close(); admin.close(); codex.stop(); throw error; }
  return { admin, phone, close: async () => {
    clearInterval(heartbeat);
    for (const [ws, session] of phones) { session.close(); ws.terminate(); }
    wss.close(); codex.stop();
    await Promise.all([new Promise(resolve => admin.close(resolve)), new Promise(resolve => phone.close(resolve))]);
  } };
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const bridge = await startBridge();
  console.log('RayBridge is ready. Open http://127.0.0.1:8844 on this Mac.');
  for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, async () => { await bridge.close(); process.exit(0); });
}
