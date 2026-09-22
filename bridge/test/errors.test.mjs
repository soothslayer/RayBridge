import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { ERROR_CATALOG, codedError, errorEvent, signOutFix } from '../errors.mjs';
import { PhoneSession } from '../session.mjs';

test('every catalog entry is speakable: non-empty message, string fix', () => {
  assert.ok(Object.keys(ERROR_CATALOG).length > 0);
  for (const [code, entry] of Object.entries(ERROR_CATALOG)) {
    assert.equal(typeof entry.message, 'string', code);
    assert.ok(entry.message.length > 0, code);
    assert.equal(typeof entry.fix, 'string', code);
  }
});

test('errorEvent builds the phone event shape and honors overrides', () => {
  const event = errorEvent('turn.failed');
  assert.deepEqual(event, { type: 'error', code: 'turn.failed',
    message: 'The answer was interrupted or empty.',
    fix: 'Try asking again. If it keeps failing, reopen RayBridge on your Mac and say start.' });
  const overridden = errorEvent('turn.failed', { message: 'Custom.' });
  assert.equal(overridden.message, 'Custom.');
  assert.equal(overridden.fix, event.fix);
  const unknown = errorEvent('nope.not-real');
  assert.equal(unknown.type, 'error');
  assert.equal(unknown.code, 'nope.not-real');
  assert.ok(unknown.message.length > 0);
});

test('signOutFix names the right Mac-side action per assistant', () => {
  assert.match(signOutFix('claude'), /claude auth login/);
  assert.match(signOutFix('hermes'), /Hermes/);
  assert.match(signOutFix('codex'), /ChatGPT/);
  assert.match(signOutFix(undefined), /ChatGPT/);
});

test('codedError throws an Error carrying its code and fix', () => {
  const error = codedError('turn.busy');
  assert.ok(error instanceof Error);
  assert.equal(error.code, 'turn.busy');
  assert.equal(error.message, 'An answer is already in progress.');
  assert.match(error.fix, /cancel/);
});

class FakeAssistant extends EventEmitter {
  calls = []; signedIn = true; provider = 'claude';
  async account() { return { signedIn: this.signedIn }; }
  async newThread() { return 'thread-1'; }
  async ask() { return { turn: { id: 'turn-1' } }; }
  async call() {}
}
function setup(options = {}) {
  const assistant = new FakeAssistant(), output = [];
  const session = new PhoneSession(assistant, event => output.push(event), { now: Date.now, log: () => {}, ...options });
  return { assistant, output, session };
}

test('a signed-out assistant rejects the question with an actionable fix', async t => {
  const { assistant, session } = setup(); t.after(() => session.close());
  assistant.signedIn = false; assistant.provider = 'claude';
  const error = await session.receive({ type: 'ask', text: 'Hello' }).catch(e => e);
  assert.equal(error.code, 'assistant.signed-out');
  assert.match(error.message, /Sign in/);
  assert.match(error.fix, /claude auth login/);
});

test('a failed turn sends a coded error event with its fix', async t => {
  const { session, output } = setup(); t.after(() => session.close());
  await session.receive({ type: 'ask', text: 'Hello' });
  session.notification({ method: 'turn/completed',
    params: { threadId: 'thread-1', turn: { id: 'turn-1', status: 'failed' } } });
  const event = output.find(e => e.type === 'error');
  assert.equal(event.code, 'turn.failed');
  assert.ok(event.message.length > 0);
  assert.ok(event.fix.length > 0);
});

test('a failed turn keeps the assistant-provided message but still fixes', async t => {
  const { session, output } = setup(); t.after(() => session.close());
  await session.receive({ type: 'ask', text: 'Hello' });
  session.notification({ method: 'turn/completed',
    params: { threadId: 'thread-1', turn: { id: 'turn-1', status: 'failed', error: { message: 'Boom.' } } } });
  const event = output.find(e => e.type === 'error');
  assert.equal(event.code, 'turn.failed');
  assert.equal(event.message, 'Boom.');
  assert.ok(event.fix.length > 0);
});

test('validation failures carry codes the phone can rely on', async t => {
  const { session } = setup(); t.after(() => session.close());
  const busy = await session.receive({ type: 'ask', text: 'one' }).then(() => null, e => e);
  assert.equal(busy, null); // first question accepted
  const second = await session.receive({ type: 'ask', text: 'two' }).then(() => null, e => e);
  assert.equal(second.code, 'turn.busy');
  session.cancel();
  const bad = await session.receive({ type: 'ask', text: '   ' }).then(() => null, e => e);
  assert.equal(bad.code, 'question.invalid');
  const unknown = await session.receive({ type: 'nope' }).then(() => null, e => e);
  assert.equal(unknown.code, 'message.invalid');
});
