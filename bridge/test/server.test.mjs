import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter, once } from 'node:events';
import { mkdir, mkdtemp, readFile, rm } from 'node:fs/promises';
import { X509Certificate } from 'node:crypto';
import http from 'node:http';
import { WebSocket } from 'ws';
import { startBridge, authorized } from '../server.mjs';

class FakeCodex extends EventEmitter {
  accountSource = 'raybridge';
  workspace = '/Users/test';
  async start() {}
  stop() {}
  async account() { return { signedIn: true, plan: 'plus', accountSource: this.accountSource }; }
  async setAccountSource(source) { this.accountSource = source; }
  async setWorkspace(workspace) { this.workspace = workspace; }
  setAllowedApps(apps) { this.allowedApps = apps; }
  async newThread() { return 'test-thread'; }
  async call() { return {}; }
  async ask(threadId) {
    setTimeout(() => {
      this.emit('notification', { method: 'item/completed', params: { threadId, turnId: 'turn-1', item: { type: 'agentMessage', phase: 'final_answer', text: 'A blue mug.' } } });
      this.emit('notification', { method: 'turn/completed', params: { threadId, turn: { id: 'turn-1', status: 'completed' } } });
    }, 10);
    return { turn: { id: 'turn-1' } };
  }
}

test('pairing tokens require an exact bearer match', () => {
  assert.equal(authorized('Bearer secret', 'secret'), true);
  for (const value of [undefined, '', 'secret', 'Bearer wrong', ['Bearer secret']]) assert.equal(authorized(value, 'secret'), false);
});

test('HTTPS bridge authenticates, isolates admin, and completes a phone question', async t => {
  const dataDir = await mkdtemp('/tmp/raybridge-test-');
  const bridge = await startBridge({ dataDir, adminPort: 0, phonePort: 0, codex: new FakeCodex() });
  const sockets = [];
  t.after(async () => { sockets.forEach(ws => ws.terminate()); await bridge.close(); await rm(dataDir, { recursive: true, force: true }); });
  const admin = `http://127.0.0.1:${bridge.admin.address().port}`;
  const phone = `wss://127.0.0.1:${bridge.phone.address().port}/v1/connect`;
  const token = (await readFile(`${dataDir}/phone-token`, 'utf8')).trim();
  const cert = new X509Certificate(await readFile(`${dataDir}/server.crt`));
  assert.ok(cert.fingerprint256);
  const status = await (await fetch(`${admin}/api/status`)).json();
  assert.equal(status.signedIn, true);
  assert.equal(status.accountSource, 'raybridge');
  const badHostStatus = await new Promise((resolve, reject) => {
    http.get(`${admin}/api/status`, { headers: { Host: 'evil.example' } }, res => { res.resume(); resolve(res.statusCode); }).on('error', reject);
  });
  assert.equal(badHostStatus, 403);
  assert.equal((await fetch(`${admin}/api/logout`, { method: 'POST' })).status, 403);
  assert.equal((await fetch(`${admin}/api/logout`, { method: 'POST', headers: { 'X-RayBridge': 'local', Origin: 'https://evil.example' } })).status, 403);
  const rejected = new WebSocket(phone, { rejectUnauthorized: false });
  rejected.on('error', () => {});
  assert.equal((await once(rejected, 'unexpected-response'))[1].statusCode, 401);
  rejected.terminate();
  const ws = new WebSocket(phone, { rejectUnauthorized: false, headers: { Authorization: `Bearer ${token}` } });
  sockets.push(ws);
  const events = [];
  ws.on('message', data => events.push(JSON.parse(data)));
  await once(ws, 'open');
  while (!events.some(x => x.type === 'ready')) await new Promise(resolve => setTimeout(resolve, 10));
  const answer = new Promise(resolve => ws.on('message', data => { const e = JSON.parse(data); if (e.type === 'answer') resolve(e); }));
  ws.send(JSON.stringify({ type: 'ask', text: 'What is this?' }));
  assert.deepEqual(await answer, { type: 'answer', text: 'A blue mug.' });
  const closed = once(ws, 'close');
  assert.equal((await fetch(`${admin}/api/revoke`, { method: 'POST', headers: { 'X-RayBridge': 'local' } })).status, 200);
  await closed;
  assert.notEqual((await readFile(`${dataDir}/phone-token`, 'utf8')).trim(), token);
});

test('local Codex login can be selected without exposing logout', async t => {
  const dataDir = await mkdtemp('/tmp/raybridge-source-test-');
  const codex = new FakeCodex();
  const applicationProvider = async () => [
    { id: 'com.apple.calculator', name: 'Calculator' },
    { id: 'com.apple.TextEdit', name: 'TextEdit' }
  ];
  const bridge = await startBridge({ dataDir, adminPort: 0, phonePort: 0, codex, applicationProvider });
  t.after(async () => { await bridge.close(); await rm(dataDir, { recursive: true, force: true }); });
  const admin = `http://127.0.0.1:${bridge.admin.address().port}`;
  const headers = { 'X-RayBridge': 'local', 'Content-Type': 'application/json' };
  const changed = await fetch(`${admin}/api/account-source`, {
    method: 'POST', headers, body: JSON.stringify({ source: 'local' })
  });
  assert.equal(changed.status, 200);
  assert.equal((await changed.json()).accountSource, 'local');
  assert.equal((await readFile(`${dataDir}/codex-account-source`, 'utf8')).trim(), 'local');
  assert.equal((await fetch(`${admin}/api/logout`, { method: 'POST', headers: { 'X-RayBridge': 'local' } })).status, 400);
  const status = await (await fetch(`${admin}/api/status`)).json();
  assert.equal(status.accountSource, 'local');
  const workspace = `${dataDir}/workspace`;
  await mkdir(workspace);
  const changedWorkspace = await fetch(`${admin}/api/workspace`, {
    method: 'POST', headers, body: JSON.stringify({ path: workspace })
  });
  assert.equal(changedWorkspace.status, 200);
  const selectedWorkspace = (await changedWorkspace.json()).workspace;
  assert.equal(codex.workspace, selectedWorkspace);
  assert.equal((await readFile(`${dataDir}/codex-workspace`, 'utf8')).trim(), selectedWorkspace);
  const apps = await (await fetch(`${admin}/api/apps`)).json();
  assert.deepEqual(apps, { applications: await applicationProvider(), selected: [] });
  const changedApps = await fetch(`${admin}/api/apps`, {
    method: 'POST', headers, body: JSON.stringify({ apps: ['com.apple.calculator'] })
  });
  assert.equal(changedApps.status, 200);
  assert.deepEqual(codex.allowedApps, ['com.apple.calculator']);
  assert.deepEqual(JSON.parse(await readFile(`${dataDir}/computer-use-apps.json`, 'utf8')), ['com.apple.calculator']);
  assert.equal((await fetch(`${admin}/api/apps`, {
    method: 'POST', headers, body: JSON.stringify({ apps: ['com.apple.Terminal'] })
  })).status, 400);
  assert.equal((await fetch(`${admin}/api/account-source`, {
    method: 'POST', headers, body: JSON.stringify({ source: 'invalid' })
  })).status, 400);
});

test('Mac setup reports and starts the optional Kokoro download', async t => {
  const dataDir = await mkdtemp('/tmp/raybridge-tts-api-test-');
  let started = 0;
  const tts = {
    async status() { return { installed: false, installing: started > 0, progress: started ? 25 : null, detail: 'Optional voice', error: null }; },
    async startInstall() { started += 1; return this.status(); },
    async synthesize() { throw new Error('unused'); }
  };
  const bridge = await startBridge({ dataDir, adminPort: 0, phonePort: 0, codex: new FakeCodex(), tts });
  t.after(async () => { await bridge.close(); await rm(dataDir, { recursive: true, force: true }); });
  const admin = `http://127.0.0.1:${bridge.admin.address().port}`;
  assert.equal((await (await fetch(`${admin}/api/tts/status`)).json()).installing, false);
  const response = await fetch(`${admin}/api/tts/install`, { method: 'POST', headers: { 'X-RayBridge': 'local' } });
  assert.equal(response.status, 202);
  assert.equal((await response.json()).progress, 25);
  assert.equal(started, 1);
});
