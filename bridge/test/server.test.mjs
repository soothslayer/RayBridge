import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter, once } from 'node:events';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { X509Certificate } from 'node:crypto';
import http from 'node:http';
import { WebSocket } from 'ws';
import { startBridge, authorized } from '../server.mjs';

class FakeCodex extends EventEmitter {
  async start() {}
  stop() {}
  async account() { return { signedIn: true, plan: 'plus' }; }
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
  const missingImage = new Promise(resolve => ws.on('message', data => {
    const event = JSON.parse(data); if (event.type === 'error') resolve(event);
  }));
  ws.send(JSON.stringify({ type: 'ask', text: 'What is this?', requiresImage: true }));
  assert.equal((await missingImage).code, 'camera_unavailable');
  assert.equal(events.some(event => event.type === 'answer' || event.type === 'thinking'), false);
  const answer = new Promise(resolve => ws.on('message', data => { const e = JSON.parse(data); if (e.type === 'answer') resolve(e); }));
  ws.send(JSON.stringify({ type: 'frame', jpeg: Buffer.from([255, 216, 0, 255, 217]).toString('base64') }));
  ws.send(JSON.stringify({ type: 'ask', text: 'What is this?', requiresImage: true }));
  assert.deepEqual(await answer, { type: 'answer', text: 'A blue mug.' });
  const closed = once(ws, 'close');
  assert.equal((await fetch(`${admin}/api/revoke`, { method: 'POST', headers: { 'X-RayBridge': 'local' } })).status, 200);
  await closed;
  assert.notEqual((await readFile(`${dataDir}/phone-token`, 'utf8')).trim(), token);
});
