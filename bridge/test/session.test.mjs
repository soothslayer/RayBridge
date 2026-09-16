import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PhoneSession, validJPEG } from '../session.mjs';

class FakeCodex extends EventEmitter {
  calls = []; signedIn = true;
  async account() { return { signedIn: this.signedIn }; }
  async newThread() { this.calls.push(['thread']); return 'thread-1'; }
  async ask(thread, text, frame) { this.calls.push(['ask', thread, text, frame]); return { turn: { id: 'turn-1' } }; }
  async call(method, params) { this.calls.push([method, params]); }
}
const jpeg = Buffer.from([255, 216, 0, 255, 217]).toString('base64');
function setup() {
  const codex = new FakeCodex(), output = [];
  let time = 10000;
  const session = new PhoneSession(codex, event => output.push(event), { now: () => time });
  return { codex, output, session, advance: ms => { time += ms; } };
}
test('validates camera input and bounds payloads', () => {
  assert.equal(validJPEG(jpeg), true);
  for (const value of ['', null, 'hello', 'a'.repeat(700000), Buffer.from('not JPEG').toString('base64')]) assert.equal(validJPEG(value), false);
});
test('fresh frame accompanies a question; frames alone do not invoke the model', async t => {
  const { codex, session, output } = setup(); t.after(() => session.close());
  await session.receive({ type: 'frame', jpeg }); assert.equal(codex.calls.length, 0);
  await session.receive({ type: 'ask', text: 'What is in front of me?' });
  assert.equal(codex.calls[1][3], jpeg); assert.equal(output[0].hasImage, true);
  await assert.rejects(session.receive({ type: 'ask', text: 'second' }), /already/);
});
test('stale frames and camera-off are never reused', async t => {
  const { codex, session, advance } = setup(); t.after(() => session.close());
  await session.receive({ type: 'frame', jpeg }); advance(4000);
  await session.receive({ type: 'ask', text: 'Look' }); assert.equal(codex.calls[1][3], null);
  session.cancel(); await session.receive({ type: 'frame', jpeg });
  await session.receive({ type: 'camera.off' });
  await session.receive({ type: 'ask', text: 'Look again' });
  assert.equal(codex.calls.at(-1)[3], null);
});
test('required-image questions never invoke the model with missing or stale frames', async t => {
  const { codex, session, advance, output } = setup(); t.after(() => session.close());
  const ask = () => session.receive({ type: 'ask', text: 'Describe what I see', requiresImage: true });
  await assert.rejects(ask(), { code: 'camera_unavailable' });
  await session.receive({ type: 'frame', jpeg }); advance(4000);
  await assert.rejects(ask(), { code: 'camera_unavailable' });
  await session.receive({ type: 'frame', jpeg });
  await session.receive({ type: 'camera.off' });
  await assert.rejects(ask(), { code: 'camera_unavailable' });
  assert.equal(codex.calls.some(call => call[0] === 'ask'), false);
  assert.equal(output.some(event => event.type === 'thinking'), false);
  await session.receive({ type: 'frame', jpeg });
  await ask();
  assert.equal(codex.calls.at(-1)[3], jpeg);
  assert.equal(output.at(-1).hasImage, true);
});
test('required image expiring during thread startup is rejected before inference', async t => {
  const { codex, session, advance } = setup(); t.after(() => session.close());
  codex.newThread = async () => { advance(4000); return 'thread-1'; };
  await session.receive({ type: 'frame', jpeg });
  await assert.rejects(session.receive({ type: 'ask', text: 'Look', requiresImage: true }), { code: 'camera_unavailable' });
  assert.equal(codex.calls.some(call => call[0] === 'ask'), false);
});
test('subscription sign-in required; empty and oversized questions rejected', async t => {
  const { codex, session } = setup(); t.after(() => session.close()); codex.signedIn = false;
  await assert.rejects(session.receive({ type: 'ask', text: 'Hello' }), /Sign in/);
  assert.equal(codex.calls.length, 0);
  for (const text of ['', '   ', 'a'.repeat(4001)]) await assert.rejects(session.receive({ type: 'ask', text }), /question/);
});
test('only final assistant text in the current turn is spoken', async t => {
  const { codex, session, output } = setup(); t.after(() => session.close());
  await session.receive({ type: 'ask', text: 'Hello' });
  const item = (threadId, phase, text) => codex.emit('notification', { method: 'item/completed', params: { threadId, turnId: 'turn-1', item: { type: 'agentMessage', phase, text } } });
  item('another-thread', 'final_answer', 'private'); item('thread-1', 'commentary', 'working');
  item('thread-1', 'final_answer', 'Hello there');
  codex.emit('notification', { method: 'turn/completed', params: { threadId: 'thread-1', turn: { id: 'turn-1', status: 'completed' } } });
  assert.deepEqual(output.at(-1), { type: 'answer', text: 'Hello there' });
});
test('close interrupts inference, removes listener, and releases camera memory', async () => {
  const { codex, session } = setup();
  await session.receive({ type: 'frame', jpeg }); await session.receive({ type: 'ask', text: 'Hello' });
  session.close(); assert.equal(session.frame, null); assert.equal(codex.listenerCount('notification'), 0);
  assert.equal(codex.calls.at(-1)[0], 'turn/interrupt');
});
test('disconnect during thread creation prevents a later model request', async () => {
  const { codex, session } = setup();
  let finish;
  codex.newThread = () => new Promise(resolve => { finish = resolve; });
  const asking = session.receive({ type: 'ask', text: 'Hello' });
  await new Promise(resolve => setImmediate(resolve));
  session.close(); finish('thread-1'); await asking;
  assert.equal(codex.calls.length, 0);
});
test('late completion of a cancelled turn cannot answer the next question', async t => {
  const { codex, session, output } = setup(); t.after(() => session.close());
  await session.receive({ type: 'ask', text: 'First' });
  session.cancel();
  codex.ask = async () => ({ turn: { id: 'turn-2' } });
  await session.receive({ type: 'ask', text: 'Second' });
  codex.emit('notification', { method: 'turn/started', params: { threadId: 'thread-1', turn: { id: 'turn-1' } } });
  codex.emit('notification', { method: 'item/completed', params: { threadId: 'thread-1', turnId: 'turn-1', item: { type: 'agentMessage', text: 'Old answer' } } });
  codex.emit('notification', { method: 'turn/completed', params: { threadId: 'thread-1', turn: { id: 'turn-1', status: 'completed' } } });
  assert.equal(output.some(x => x.type === 'answer'), false);
  assert.equal(session.active.turnId, 'turn-2');
});
