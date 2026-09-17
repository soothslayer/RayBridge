import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { AssistantRouter } from '../assistant.mjs';

class FakeAssistant extends EventEmitter {
  constructor(name) { super(); this.name = name; this.workspace = `/tmp/${name}`; }
  async start() { this.starts = (this.starts || 0) + 1; }
  stop() { this.stops = (this.stops || 0) + 1; }
  async account() { return { signedIn: true, plan: this.name }; }
  async newThread() { return `${this.name}-thread`; }
  async ask() { return { turn: { id: `${this.name}-turn` } }; }
  async call() { return {}; }
}

test('assistant router switches backends and only forwards the active backend', async () => {
  const codex = new FakeAssistant('codex');
  const claude = new FakeAssistant('claude');
  const router = new AssistantRouter({ codex, claude });
  const notifications = [];
  router.on('notification', message => notifications.push(message));
  await router.start();
  codex.emit('notification', { method: 'codex' });
  claude.emit('notification', { method: 'inactive' });
  await router.setProvider('claude');
  codex.emit('notification', { method: 'stopped' });
  claude.emit('notification', { method: 'claude' });
  assert.deepEqual(notifications.map(x => x.method), ['codex', 'claude']);
  assert.equal(codex.stops, 1);
  assert.equal(claude.starts, 1);
  assert.equal((await router.account()).provider, 'claude');
  assert.equal(await router.newThread(), 'claude-thread');
  await assert.rejects(router.setProvider('other'), /valid assistant/);
});

test('assistant router restores the previous backend when a switch fails', async () => {
  const codex = new FakeAssistant('codex');
  const claude = new FakeAssistant('claude');
  claude.start = async () => { throw new Error('Claude failed to start.'); };
  const router = new AssistantRouter({ codex, claude });
  await router.start();
  await assert.rejects(router.setProvider('claude'), /failed to start/);
  assert.equal(router.provider, 'codex');
  assert.equal(codex.starts, 2);
  assert.equal(claude.stops, 1);
});
