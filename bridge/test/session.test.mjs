import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PhoneSession, splitSpokenChunk, validJPEG } from '../session.mjs';

class FakeCodex extends EventEmitter {
  calls = []; signedIn = true; accountReads = 0;
  async account() { this.accountReads += 1; return { signedIn: this.signedIn }; }
  async newThread() { this.calls.push(['thread']); return 'thread-1'; }
  async ask(thread, text, frame) { this.calls.push(['ask', thread, text, frame]); return { turn: { id: 'turn-1' } }; }
  async call(method, params) { this.calls.push([method, params]); }
}
const jpeg = Buffer.from([255, 216, 0, 255, 217]).toString('base64');
function setup(options = {}) {
  const codex = new FakeCodex(), output = [];
  let time = 10000;
  const session = new PhoneSession(codex, event => output.push(event), {
    now: () => time, log: () => {}, ...options });
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
test('Status reports idle, starting, and active work without changing the turn', async t => {
  const { codex, session, output } = setup(); t.after(() => session.close());
  await session.receive({ type: 'status' });
  assert.equal(output.at(-1).text, 'No task is running. RayBridge is listening.');
  let finishThread;
  codex.newThread = () => new Promise(resolve => { finishThread = resolve; });
  const asking = session.receive({ type: 'ask', text: 'Hello' });
  await new Promise(resolve => setImmediate(resolve));
  await session.receive({ type: 'status' });
  assert.equal(output.at(-1).text, 'The task is starting.');
  finishThread('thread-1'); await asking;
  await session.receive({ type: 'status' });
  assert.equal(output.at(-1).text, 'The assistant is working on your question.');
  assert.equal(session.active.turnId, 'turn-1');
});
test('Repeat speaks the latest completed answer and handles an empty history', async t => {
  const { codex, session, output } = setup(); t.after(() => session.close());
  await session.receive({ type: 'repeat' });
  assert.equal(output.at(-1).text, 'There is no completed answer to repeat yet.');
  await session.receive({ type: 'ask', text: 'Hello' });
  codex.emit('notification', { method: 'item/completed', params: {
    threadId: 'thread-1', turnId: 'turn-1', item: { type: 'agentMessage', text: 'The saved answer.' } } });
  codex.emit('notification', { method: 'turn/completed', params: {
    threadId: 'thread-1', turn: { id: 'turn-1', status: 'completed' } } });
  await session.receive({ type: 'repeat' });
  assert.deepEqual(output.at(-1), { type: 'coordinator.speech', text: 'The saved answer.' });
});
test('Kokoro audio is attached to the final answer', async t => {
  const tts = { synthesize: async (text, voice) => {
    assert.equal(text, 'A useful answer'); assert.equal(voice, 'bf_emma');
    return { format: 'm4a', data: 'YXVkaW8=' };
  } };
  const { codex, session, output } = setup({ tts }); t.after(() => session.close());
  await session.receive({ type: 'ask', text: 'Hello', ttsEngine: 'kokoro', ttsVoice: 'bf_emma' });
  codex.emit('notification', { method: 'item/completed', params: { threadId: 'thread-1', turnId: 'turn-1', item: { type: 'agentMessage', text: 'A useful answer' } } });
  codex.emit('notification', { method: 'turn/completed', params: { threadId: 'thread-1', turn: { id: 'turn-1', status: 'completed' } } });
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(output.at(-1), { type: 'answer', text: 'A useful answer', audio: { format: 'm4a', data: 'YXVkaW8=' } });
});
test('Kokoro failure keeps the answer and requests Apple fallback', async t => {
  const { codex, session, output } = setup({ tts: { synthesize: async () => { throw new Error('Model missing'); } } });
  t.after(() => session.close());
  await session.receive({ type: 'ask', text: 'Hello', ttsEngine: 'kokoro' });
  codex.emit('notification', { method: 'item/completed', params: { threadId: 'thread-1', turnId: 'turn-1', item: { type: 'agentMessage', text: 'Still answered' } } });
  codex.emit('notification', { method: 'turn/completed', params: { threadId: 'thread-1', turn: { id: 'turn-1', status: 'completed' } } });
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(output.at(-1), { type: 'answer', text: 'Still answered', ttsFallback: 'Model missing' });
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

test('Cancel waits for a pending turn start and its interrupt before acknowledging', async t => {
  const { codex, session, output } = setup(); t.after(() => session.close());
  let finishAsk, finishInterrupt;
  codex.ask = () => new Promise(resolve => { finishAsk = resolve; });
  codex.call = () => new Promise(resolve => { finishInterrupt = resolve; });
  const asking = session.receive({ type: 'ask', text: 'First' });
  await new Promise(resolve => setImmediate(resolve));
  const cancelling = session.receive({ type: 'cancel' });
  assert.equal(output.some(x => x.type === 'cancelled'), false);
  await assert.rejects(session.receive({ type: 'ask', text: 'Too soon' }), /already/);
  finishAsk({ turn: { id: 'old-turn' } });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(output.some(x => x.type === 'cancelled'), false);
  finishInterrupt({});
  await Promise.all([asking, cancelling]);
  assert.equal(output.at(-1).type, 'cancelled');
  codex.ask = async () => ({ turn: { id: 'new-turn' } });
  await session.receive({ type: 'ask', text: 'Next question' });
  assert.equal(session.active.turnId, 'new-turn');
});

test('Cancel discards audio arriving from Kokoro after cancellation', async t => {
  let finishAudio;
  const { codex, session, output } = setup({ tts: {
    synthesize: () => new Promise(resolve => { finishAudio = resolve; })
  } });
  t.after(() => session.close());
  await session.receive({ type: 'ask', text: 'Hello', ttsEngine: 'kokoro' });
  codex.emit('notification', { method: 'item/completed', params: { threadId: 'thread-1', turnId: 'turn-1', item: { type: 'agentMessage', text: 'Old answer' } } });
  codex.emit('notification', { method: 'turn/completed', params: { threadId: 'thread-1', turn: { id: 'turn-1', status: 'completed' } } });
  await session.receive({ type: 'cancel' });
  codex.ask = async () => ({ turn: { id: 'new-turn' } });
  await session.receive({ type: 'ask', text: 'New question' });
  finishAudio({ format: 'm4a', data: 'YXVkaW8=' });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(output.some(x => x.type === 'answer'), false);
  assert.equal(session.active.turnId, 'new-turn');
});

test('a failed cancelled request does not report an error after Cancel', async t => {
  const { codex, session, output } = setup(); t.after(() => session.close());
  let failAsk;
  codex.ask = () => new Promise((resolve, reject) => { failAsk = reject; });
  const asking = session.receive({ type: 'ask', text: 'Hello' });
  await new Promise(resolve => setImmediate(resolve));
  const cancelling = session.receive({ type: 'cancel' });
  failAsk(new Error('Turn cancelled'));
  await Promise.all([asking, cancelling]);
  assert.equal(output.at(-1).type, 'cancelled');
});

test('Cancel does not claim cancellation succeeded when the interrupt fails', async t => {
  const { codex, session, output } = setup(); t.after(() => session.close());
  await session.receive({ type: 'ask', text: 'Hello' });
  codex.call = async () => { throw new Error('Interrupt failed'); };
  await assert.rejects(session.receive({ type: 'cancel' }), /Interrupt failed/);
  assert.equal(output.some(x => x.type === 'cancelled'), false);
});

test('Cancel interrupts a known turn only once while its start response is pending', async t => {
  const { codex, session, output } = setup(); t.after(() => session.close());
  let finishAsk;
  codex.ask = () => new Promise(resolve => { finishAsk = resolve; });
  const asking = session.receive({ type: 'ask', text: 'Hello' });
  await new Promise(resolve => setImmediate(resolve));
  codex.emit('notification', { method: 'turn/started', params: { threadId: 'thread-1', turn: { id: 'pending-turn' } } });
  const cancelling = session.receive({ type: 'cancel' });
  finishAsk({ turn: { id: 'pending-turn' } });
  await Promise.all([asking, cancelling]);
  assert.equal(codex.calls.filter(x => x[0] === 'turn/interrupt').length, 1);
  assert.equal(output.at(-1).type, 'cancelled');
});

test('a sentence is only released once it has finished', () => {
  assert.deepEqual(splitSpokenChunk('The sign says'), ['', 'The sign says']);
  assert.deepEqual(splitSpokenChunk('It is a door. It is'), ['It is a door. ', 'It is']);
  assert.deepEqual(splitSpokenChunk('Two lines\nand more'), ['Two lines\n', 'and more']);
  assert.deepEqual(splitSpokenChunk('Is it open? Yes! '), ['Is it open? Yes! ', '']);
});
test('finished sentences are spoken before the turn completes, without repeating them', async t => {
  const { codex, session, output } = setup(); t.after(() => session.close());
  await session.receive({ type: 'ask', text: 'What is there?' });
  const delta = text => codex.emit('notification', { method: 'item/delta', params: {
    threadId: 'thread-1', turnId: 'turn-1', item: { type: 'agentMessage', phase: 'final_answer', text } } });
  delta('A red door');
  assert.equal(output.filter(event => event.type === 'answer.partial').length, 0);
  delta('A red door. It is');
  delta('A red door. It is closed.\n');
  assert.deepEqual(output.filter(event => event.type === 'answer.partial').map(event => event.text),
    ['A red door. ', 'It is closed.\n']);
  codex.emit('notification', { method: 'turn/completed', params: { threadId: 'thread-1', turn: { id: 'turn-1', status: 'completed' } } });
  assert.equal(output.at(-1).type, 'error');
});
test('replaced text is withdrawn so preparation is never spoken as the answer', async t => {
  const { codex, session, output } = setup(); t.after(() => session.close());
  await session.receive({ type: 'ask', text: 'Read this' });
  const delta = text => codex.emit('notification', { method: 'item/delta', params: {
    threadId: 'thread-1', turnId: 'turn-1', item: { type: 'agentMessage', phase: 'final_answer', text } } });
  delta('Let me look. ');
  codex.emit('notification', { method: 'item/discarded', params: { threadId: 'thread-1', turnId: 'turn-1' } });
  assert.equal(output.at(-1).type, 'answer.discard');
  delta('The sign says closed. ');
  assert.deepEqual(output.at(-1), { type: 'answer.partial', text: 'The sign says closed. ' });
  // Shrinking text is a replacement too, even without an explicit withdrawal.
  delta('Short');
  assert.equal(output.at(-1).type, 'answer.discard');
});
test('Kokoro answers are not streamed because the Mac generates one audio file', async t => {
  const { codex, session, output } = setup({ tts: { synthesize: async () => ({ format: 'm4a', data: 'YXVkaW8=' }) } });
  t.after(() => session.close());
  await session.receive({ type: 'ask', text: 'Hello', ttsEngine: 'kokoro' });
  codex.emit('notification', { method: 'item/delta', params: {
    threadId: 'thread-1', turnId: 'turn-1', item: { type: 'agentMessage', text: 'A finished sentence. ' } } });
  assert.equal(output.some(event => event.type === 'answer.partial'), false);
});
test('a proven account is reused instead of read before every question', async t => {
  const { codex, session, advance } = setup({ account: { signedIn: true }, accountCacheMs: 60000 });
  t.after(() => session.close());
  await session.receive({ type: 'ask', text: 'First' });
  assert.equal(codex.accountReads, 0);
  session.cancel();
  await session.receive({ type: 'ask', text: 'Second' });
  assert.equal(codex.accountReads, 0);
  advance(60001);
  session.cancel();
  await session.receive({ type: 'ask', text: 'Third' });
  assert.equal(codex.accountReads, 1);
});
test('a failed turn forces the next question to read the account again', async t => {
  const { codex, session } = setup({ account: { signedIn: true } });
  t.after(() => session.close());
  await session.receive({ type: 'ask', text: 'First' });
  codex.emit('notification', { method: 'turn/completed', params: { threadId: 'thread-1', turn: { id: 'turn-1', status: 'failed' } } });
  codex.signedIn = false;
  await assert.rejects(session.receive({ type: 'ask', text: 'Second' }), /Sign in/);
  assert.equal(codex.accountReads, 1);
});
test('turn stages are timed without recording what was asked or answered', async t => {
  const lines = [];
  const { codex, session, advance } = setup({ log: line => lines.push(line) });
  t.after(() => session.close());
  await session.receive({ type: 'ask', text: 'A private question' });
  advance(40);
  codex.emit('notification', { method: 'item/delta', params: {
    threadId: 'thread-1', turnId: 'turn-1', item: { type: 'agentMessage', text: 'A private answer. ' } } });
  advance(10);
  codex.emit('notification', { method: 'item/completed', params: {
    threadId: 'thread-1', turnId: 'turn-1', item: { type: 'agentMessage', text: 'A private answer.' } } });
  codex.emit('notification', { method: 'turn/completed', params: { threadId: 'thread-1', turn: { id: 'turn-1', status: 'completed' } } });
  assert.equal(lines.length, 1);
  assert.match(lines[0], /firstSpokenSentence=40 answerComplete=50/);
  assert.equal(/private/.test(lines[0]), false);
});
