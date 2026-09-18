import http from 'node:http';
import https from 'node:https';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { mkdir, readFile, writeFile, chmod } from 'node:fs/promises';
import { execFile, execFileSync } from 'node:child_process';
import { promisify } from 'node:util';
import { randomBytes, timingSafeEqual, X509Certificate } from 'node:crypto';
import { WebSocketServer, WebSocket } from 'ws';
import QRCode from 'qrcode';
import { CodexClient, accountSources, resolveWorkspace, validateAllowedApps } from './codex.mjs';
import { ClaudeClient } from './claude.mjs';
import { HermesClient } from './hermes.mjs';
import { AssistantRouter, assistantProviders } from './assistant.mjs';
import { PhoneSession } from './session.mjs';
import { KokoroService } from './tts.mjs';

export function authorized(header, token) {
  const actual = Buffer.from(typeof header === 'string' ? header : '');
  const expected = Buffer.from(`Bearer ${token}`);
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}
async function readJSON(req, maximum = 1024) {
  const chunks = [];
  let length = 0;
  for await (const chunk of req) {
    length += chunk.length;
    if (length > maximum) throw new Error('Request is too large.');
    chunks.push(chunk);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); }
  catch { throw new Error('Expected a JSON request.'); }
}
const root = path.dirname(fileURLToPath(import.meta.url));
const execFileAsync = promisify(execFile);
const blockedComputerUseApps = new Set([
  'com.openai.chat', 'com.openai.codex', 'com.apple.Terminal', 'com.googlecode.iterm2',
  'com.mitchellh.ghostty', 'dev.warp.Warp-Stable'
]);

export async function installedApplications() {
  const { stdout } = await execFileAsync('/usr/bin/mdfind', ['-0', "kMDItemContentType == 'com.apple.application-bundle'"],
    { maxBuffer: 4 * 1024 * 1024, timeout: 15000 });
  const applicationRoots = ['/Applications/', '/System/Applications/', path.join(os.homedir(), 'Applications/')];
  const paths = [...new Set(stdout.split('\0').filter(appPath => appPath.endsWith('.app') &&
    applicationRoots.some(prefix => appPath.startsWith(prefix)) && !appPath.includes('.app/')))];
  if (!paths.length) return [];
  const identifiers = await execFileAsync('/usr/bin/mdls', ['-raw', '-name', 'kMDItemCFBundleIdentifier', ...paths],
    { maxBuffer: 4 * 1024 * 1024, timeout: 15000 });
  const ids = identifiers.stdout.split('\0');
  const applications = paths.map((appPath, index) => {
    const id = ids[index]?.trim();
    if (!/^[A-Za-z0-9.-]{1,255}$/.test(id) || blockedComputerUseApps.has(id)) return null;
    return { id, name: path.basename(appPath, '.app') };
  });
  const byId = new Map();
  for (const app of applications) if (app && (!byId.has(app.id) || app.name.length < byId.get(app.id).name.length)) byId.set(app.id, app);
  return [...byId.values()].sort((a, b) => a.name.localeCompare(b.name));
}

export async function startBridge({ dataDir = process.env.RAYBRIDGE_DATA_DIR || path.join(os.homedir(), 'Library/Application Support/RayBridge'),
  adminPort = 8844, phonePort = 8845, codex: suppliedCodex, applicationProvider = installedApplications,
  claude: suppliedClaude, hermes: suppliedHermes, assistant: suppliedAssistant, tts: suppliedTTS } = {}) {
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
  const sourcePath = path.join(dataDir, 'codex-account-source');
  let accountSource = 'raybridge';
  try {
    const saved = (await readFile(sourcePath, 'utf8')).trim();
    if (accountSources.has(saved)) accountSource = saved;
  } catch {}
  const workspacePath = path.join(dataDir, 'codex-workspace');
  let workspace = os.homedir();
  try { workspace = await resolveWorkspace((await readFile(workspacePath, 'utf8')).trim()); }
  catch { workspace = await resolveWorkspace(workspace); }
  const allowedAppsPath = path.join(dataDir, 'computer-use-apps.json');
  let allowedApps = [];
  try { allowedApps = validateAllowedApps(JSON.parse(await readFile(allowedAppsPath, 'utf8'))); } catch {}
  const codex = suppliedCodex || new CodexClient(path.join(dataDir, 'codex'), undefined, accountSource, workspace, allowedApps);
  const claude = suppliedClaude || new ClaudeClient(path.join(dataDir, 'camera-frames'), undefined, workspace);
  const hermes = suppliedHermes || new HermesClient(path.join(dataDir, 'camera-frames'), undefined, workspace);
  const providerPath = path.join(dataDir, 'assistant-provider');
  let provider = 'codex';
  try {
    const saved = (await readFile(providerPath, 'utf8')).trim();
    if (assistantProviders.has(saved)) provider = saved;
  } catch {}
  const assistant = suppliedAssistant || new AssistantRouter({ codex, claude, hermes }, provider);
  const tts = suppliedTTS || new KokoroService(dataDir);
  let serviceError = null;
  let loginPending = false;
  assistant.on('unavailable', error => { serviceError = error.message; for (const socket of wss.clients) socket.close(1011, 'Assistant connection stopped'); });
  const wss = new WebSocketServer({ noServer: true, maxPayload: 700_000, perMessageDeflate: false });
  try { await assistant.start(); } catch (error) { serviceError = error.message; }
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
    const requestedProvider = req.headers['x-raybridge-assistant'];
    if ((requestedProvider !== undefined &&
        (typeof requestedProvider !== 'string' || !assistantProviders.has(requestedProvider))) ||
        wss.clients.size >= 1) {
      socket.end('HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n'); return;
    }
    wss.handleUpgrade(req, socket, head, ws => wss.emit('connection', ws, req));
  });
  const selectProvider = async selected => {
    if (!assistantProviders.has(selected)) throw new Error('Choose a valid assistant provider.');
    if (typeof assistant.setProvider !== 'function') throw new Error('This assistant connection cannot change providers.');
    if (selected === assistant.provider && serviceError) await assistant.start();
    else await assistant.setProvider(selected);
    provider = assistant.provider || selected;
    await writeFile(providerPath, `${provider}\n`, { mode: 0o600 });
    serviceError = null; loginPending = false;
    return assistant.account();
  };
  wss.on('connection', async (ws, req) => {
    const send = value => { if (ws.readyState === WebSocket.OPEN) {
      if (ws.bufferedAmount > 1_000_000) ws.close(1013, 'Connection too slow');
      else ws.send(JSON.stringify(value));
    } };
    ws.alive = true;
    ws.on('pong', () => { ws.alive = true; });
    ws.on('error', () => ws.terminate());
    const requestedProvider = req.headers['x-raybridge-assistant'] || assistant.provider || provider;
    let account;
    try {
      account = await selectProvider(requestedProvider);
      if (!account.signedIn) throw new Error(account.signInMessage ||
        (requestedProvider === 'claude' ? 'Sign in to Claude Code on the Mac first.' : requestedProvider === 'hermes'
          ? 'Install and configure Hermes on the Mac first.' : 'Sign in with ChatGPT on the Mac first.'));
    } catch (error) {
      send({ type: 'error', message: error.message });
      const closeTimer = setTimeout(() => {
        if (ws.readyState !== WebSocket.CLOSED) ws.close(1011, 'Assistant unavailable');
      }, 1000);
      closeTimer.unref();
      return;
    }
    const session = new PhoneSession(assistant, send, { tts });
    phones.set(ws, session);
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
    ws.on('close', () => { session.close(); phones.delete(ws); });
    send({ type: 'ready', provider: requestedProvider });
  });
  const heartbeat = setInterval(() => {
    for (const ws of wss.clients) {
      if (!ws.alive) { ws.terminate(); continue; }
      ws.alive = false; ws.ping();
    }
  }, 15000);
  assistant.on('notification', message => { if (message.method === 'account/login/completed') loginPending = false; });
  const admin = http.createServer(async (req, res) => {
    // Loopback bind plus strict Host and same-origin checks prevent LAN access and DNS rebinding.
    const host = req.headers.host;
    const ownOrigin = `http://127.0.0.1:${admin.address()?.port || adminPort}`;
    if (host !== `127.0.0.1:${admin.address()?.port || adminPort}` ||
      (req.headers.origin && req.headers.origin !== ownOrigin)) return sendJSON(res, 403, { error: 'Local access only.' });
    if (req.method === 'POST' && req.headers['x-raybridge'] !== 'local') return sendJSON(res, 403, { error: 'Invalid local request.' });
    try {
      if (req.method === 'GET' && req.url === '/api/status') {
        const account = serviceError ? { signedIn: false, provider: assistant.provider } : await assistant.account();
        const hosts = Object.values(os.networkInterfaces()).flat().filter(x => x && x.family === 'IPv4' && !x.internal).map(x => x.address);
        const selectedProvider = account.provider || assistant.provider || provider;
        const selectedSource = account.accountSource || assistant.accountSource || accountSource;
        return sendJSON(res, 200, { ...account, provider: selectedProvider, accountSource: selectedSource,
          workspace: assistant.workspace || workspace,
          workspaceEditable: selectedProvider !== 'codex' || selectedSource === 'local',
          supportsAppSelection: selectedProvider === 'codex' && selectedSource === 'local',
          error: serviceError, phoneConnected: wss.clients.size > 0,
          hosts, phonePort: phone.address().port, loginPending });
      }
      if (req.method === 'GET' && req.url?.startsWith('/api/pair?')) {
        const hostIP = new URL(req.url, ownOrigin).searchParams.get('host');
        const addresses = Object.values(os.networkInterfaces()).flat().filter(Boolean).map(x => x.address);
        if (!addresses.includes(hostIP)) throw new Error('Choose a local network address.');
        const link = `raybridge://pair?${new URLSearchParams({ host: hostIP, port: String(phone.address().port), token, fingerprint })}`;
        return sendJSON(res, 200, { link, qr: await QRCode.toDataURL(link, { width: 320, margin: 2 }) });
      }
      if (req.method === 'GET' && req.url === '/api/apps') {
        const applications = await applicationProvider();
        const installed = new Set(applications.map(app => app.id));
        return sendJSON(res, 200, { applications, selected: allowedApps.filter(id => installed.has(id)) });
      }
      if (req.method === 'GET' && req.url === '/api/tts/status') {
        return sendJSON(res, 200, await tts.status());
      }
      if (req.method === 'POST' && req.url === '/api/tts/install') {
        return sendJSON(res, 202, await tts.startInstall());
      }
      if (req.method === 'POST' && req.url === '/api/provider') {
        const request = await readJSON(req);
        if (!assistantProviders.has(request.provider)) throw new Error('Choose a valid assistant provider.');
        for (const ws of wss.clients) ws.close(1000, 'Assistant provider changed');
        const account = await selectProvider(request.provider);
        return sendJSON(res, 200, { ...account, provider, error: serviceError });
      }
      if (req.method === 'POST' && req.url === '/api/login') {
        if ((assistant.provider || provider) !== 'codex') {
          throw new Error((assistant.provider || provider) === 'claude'
            ? 'Run claude auth login in Terminal to sign in to Claude Code.'
            : 'Configure Hermes from its Mac app or CLI.');
        }
        if ((assistant.accountSource || accountSource) === 'local') {
          throw new Error('RayBridge is using this Mac’s Codex login. Run codex login on this Mac, or switch to a separate RayBridge login.');
        }
        if (loginPending) throw new Error('Sign-in is already open. Finish it in your browser.');
        const login = await assistant.call('account/login/start', { type: 'chatgpt' });
        loginPending = true;
        return sendJSON(res, 200, { url: login.authUrl });
      }
      if (req.method === 'POST' && req.url === '/api/logout') {
        if ((assistant.provider || provider) !== 'codex') throw new Error((assistant.provider || provider) === 'claude'
          ? 'Sign out of Claude Code from Terminal.' : 'Manage Hermes accounts from its Mac app or CLI.');
        if ((assistant.accountSource || accountSource) === 'local') {
          throw new Error('Switch to a separate RayBridge login before signing out.');
        }
        for (const ws of wss.clients) ws.close(1000, 'Signed out on Mac');
        await assistant.call('account/logout'); loginPending = false;
        return sendJSON(res, 200, { ok: true });
      }
      if (req.method === 'POST' && req.url === '/api/account-source') {
        if ((assistant.provider || provider) !== 'codex') throw new Error('Account selection applies only to Codex.');
        const { source } = await readJSON(req);
        if (!accountSources.has(source)) throw new Error('Choose a valid Codex account source.');
        if (typeof assistant.setAccountSource !== 'function') throw new Error('This Codex connection cannot change account source.');
        for (const ws of wss.clients) ws.close(1000, 'Codex account source changed');
        serviceError = null; loginPending = false;
        try { await assistant.setAccountSource(source); }
        catch (error) { serviceError = error.message; throw error; }
        accountSource = source;
        await writeFile(sourcePath, `${source}\n`, { mode: 0o600 });
        const account = await assistant.account();
        return sendJSON(res, 200, { ...account, accountSource: source });
      }
      if (req.method === 'POST' && req.url === '/api/workspace') {
        const selectedProvider = assistant.provider || provider;
        if (selectedProvider === 'codex' && (assistant.accountSource || accountSource) !== 'local')
          throw new Error('Choose this Mac’s Codex login before changing its working folder.');
        const request = await readJSON(req, 5000);
        const resolved = await resolveWorkspace(request.path);
        if (typeof assistant.setWorkspace !== 'function') throw new Error('This assistant cannot change its working folder.');
        for (const ws of wss.clients) ws.close(1000, 'Assistant working folder changed');
        serviceError = null;
        try { await assistant.setWorkspace(resolved); }
        catch (error) { serviceError = error.message; throw error; }
        workspace = resolved;
        await writeFile(workspacePath, `${resolved}\n`, { mode: 0o600 });
        return sendJSON(res, 200, { ok: true, workspace: resolved });
      }
      if (req.method === 'POST' && req.url === '/api/apps') {
        if ((assistant.provider || provider) !== 'codex' || (assistant.accountSource || accountSource) !== 'local')
          throw new Error('Choose this Mac’s Codex login before allowing apps.');
        const requested = validateAllowedApps((await readJSON(req, 200000)).apps);
        const applications = await applicationProvider();
        const installed = new Set(applications.map(app => app.id));
        if (requested.some(id => !installed.has(id))) throw new Error('Choose apps from the installed app list.');
        if (typeof assistant.setAllowedApps !== 'function') throw new Error('This Codex connection cannot change allowed apps.');
        allowedApps = requested;
        assistant.setAllowedApps(allowedApps);
        await writeFile(allowedAppsPath, `${JSON.stringify(allowedApps, null, 2)}\n`, { mode: 0o600 });
        for (const ws of wss.clients) ws.close(1000, 'Computer Use apps changed');
        return sendJSON(res, 200, { ok: true, selected: allowedApps });
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
  catch (error) { clearInterval(heartbeat); phone.close(); admin.close(); assistant.stop(); throw error; }
  return { admin, phone, close: async () => {
    clearInterval(heartbeat);
    for (const [ws, session] of phones) { session.close(); ws.terminate(); }
    wss.close(); assistant.stop();
    await Promise.all([new Promise(resolve => admin.close(resolve)), new Promise(resolve => phone.close(resolve))]);
  } };
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const bridge = await startBridge();
  console.log('RayBridge is ready. Open http://127.0.0.1:8844 on this Mac.');
  for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, async () => { await bridge.close(); process.exit(0); });
}
