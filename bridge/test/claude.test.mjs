import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { mkdtemp, rm } from 'node:fs/promises';
import { ClaudeClient, claudePermissionMode, localClaudeCandidates } from '../claude.mjs';

class FakeChild extends EventEmitter {
  stdin = new PassThrough();
  stdout = new PassThrough();
  stderr = new PassThrough();
  kills = [];
  kill(signal) {
    this.kills.push(signal);
    queueMicrotask(() => this.emit('close', null, signal));
    return true;
  }
}
const jpeg = Buffer.from([255, 216, 0, 255, 217]).toString('base64');
const settle = () => new Promise(resolve => setImmediate(resolve));

async function client(t, options = {}) {
  const directory = await mkdtemp('/tmp/raybridge-claude-test-');
  t.after(() => rm(directory, { recursive: true, force: true }));
  const launches = [];
  const instance = new ClaudeClient('/test/claude', directory, {
    versionCheck: async executable => executable === '/test/claude',
    partialCheck: async () => true,
    spawnProcess: (executable, args, spawnOptions) => {
      const child = new FakeChild();
      launches.push({ executable, args, options: spawnOptions, child });
      return child;
    },
    ...options
  });
  await instance.start();
  const events = [];
  instance.on('notification', event => events.push(event));
  return { instance, launches, events, directory };
}
// Everything one Claude process writes for a question that succeeds.
function answer(child, text, sessionId) {
  child.stdout.write(`${JSON.stringify({ type: 'assistant', session_id: sessionId, message: { content: [{ type: 'text', text }] } })}\n`);
  child.stdout.write(`${JSON.stringify({ type: 'result', subtype: 'success', result: text, session_id: sessionId })}\n`);
}
function written(child) {
  const data = child.stdin.read();
  return (data ? data.toString() : '').trim().split('\n').filter(Boolean).map(line => JSON.parse(line));
}

test('one Claude process answers every question in a conversation', async t => {
  const { instance, launches, events } = await client(t);
  const threadId = await instance.newThread();
  await instance.ask(threadId, 'What is this?', null);
  assert.equal(launches.length, 1);
  assert.equal(launches[0].executable, '/test/claude');
  assert.equal(launches[0].options.cwd, instance.workspace);
  assert.deepEqual(launches[0].args.slice(0, 6),
    ['--print', '--verbose', '--input-format', 'stream-json', '--output-format', 'stream-json']);
  assert.ok(launches[0].args.includes('--session-id'));
  assert.ok(launches[0].args.includes('--include-partial-messages'));
  // Anything short of bypassPermissions leaves tools needing an approval that a
  // blind user on glasses has no way to give, so the request is denied silently.
  assert.deepEqual(launches[0].args.slice(6, 10),
    ['--permission-mode', 'bypassPermissions', '--permission-prompts', 'none']);
  // The question travels as a message, never as a command-line argument.
  assert.equal(launches[0].args.some(argument => argument.includes('What is this?')), false);
  assert.deepEqual(written(launches[0].child)[0].message.content, [{ type: 'text', text: 'What is this?\nNo current camera image is available.' }]);
  answer(launches[0].child, 'A blue chair.', threadId);
  await settle();
  assert.deepEqual(events.map(event => event.method), ['turn/started', 'item/completed', 'turn/completed']);
  assert.equal(events[1].params.item.text, 'A blue chair.');
  assert.equal(events[2].params.turn.status, 'completed');

  // The second question reuses the same process: no new launch, no resume.
  const second = await instance.ask(threadId, 'And now?', null);
  assert.equal(launches.length, 1);
  assert.notEqual(second.turn.id, events[0].params.turn.id);
  answer(launches[0].child, 'Still there.', threadId);
  await settle();
  assert.equal(events.at(-1).params.turn.status, 'completed');
});

test('a camera image is part of the question instead of a staged file', async t => {
  const { instance, launches } = await client(t);
  const threadId = await instance.newThread();
  await instance.ask(threadId, 'What does the sign say?', jpeg);
  const [message] = written(launches[0].child);
  assert.deepEqual(message.message.content[0],
    { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: jpeg } });
  assert.match(message.message.content[1].text, /attached to this question/);
  // No file is written for the camera frame and no directory is shared.
  assert.equal(message.message.content[1].text.includes('Read tool'), false);
  assert.equal(launches[0].args.includes('--add-dir'), false);
});

test('a new conversation replaces the process and a returning one resumes', async t => {
  const { instance, launches } = await client(t);
  const first = await instance.newThread();
  await instance.ask(first, 'Hello', null);
  answer(launches[0].child, 'Hi.', first);
  await settle();
  const second = await instance.newThread();
  await instance.ask(second, 'Fresh start', null);
  assert.equal(launches.length, 2);
  assert.deepEqual(launches[0].child.kills, ['SIGTERM']);
  assert.ok(launches[1].args.includes('--session-id'));
  assert.equal(launches[1].args.includes('--resume'), false);
  answer(launches[1].child, 'Ready.', second);
  await settle();
  // The first conversation was seen alive, so returning to it resumes it.
  await instance.ask(first, 'Back again', null);
  assert.equal(launches.length, 3);
  assert.ok(launches[2].args.includes('--resume'));
  assert.equal(launches[2].args.includes('--session-id'), false);
});

test('interruption stops the answer and keeps the process for the next question', async t => {
  const { instance, launches, events } = await client(t);
  const threadId = await instance.newThread();
  const { turn } = await instance.ask(threadId, 'Count to a thousand', null);
  written(launches[0].child);
  const interrupted = instance.call('turn/interrupt', { threadId, turnId: turn.id });
  await settle();
  assert.deepEqual(written(launches[0].child)[0],
    { type: 'control_request', request_id: 'raybridge-interrupt-1', request: { subtype: 'interrupt' } });
  // Claude reports the abandoned turn and stays open.
  launches[0].child.stdout.write(`${JSON.stringify({ type: 'result', subtype: 'error_during_execution', is_error: true, result: '', session_id: threadId })}\n`);
  await interrupted;
  assert.equal(events.at(-1).params.turn.status, 'interrupted');
  assert.deepEqual(launches[0].child.kills, []);
  await instance.ask(threadId, 'Never mind, what time is it?', null);
  assert.equal(launches.length, 1);
});

test('a process that will not stop is ended so Cancel cannot hang', async t => {
  const { instance, launches, events } = await client(t, { interruptTimeout: 10 });
  const threadId = await instance.newThread();
  const { turn } = await instance.ask(threadId, 'Count to a thousand', null);
  await instance.call('turn/interrupt', { threadId, turnId: turn.id });
  assert.deepEqual(launches[0].child.kills, ['SIGTERM']);
  assert.equal(events.at(-1).params.turn.status, 'interrupted');
  // The next question starts a new process and resumes nothing it never saw.
  await instance.ask(threadId, 'What time is it?', null);
  assert.equal(launches.length, 2);
});

test('a process that exits during an answer fails that turn and is replaced', async t => {
  const { instance, launches, events } = await client(t);
  const threadId = await instance.newThread();
  await instance.ask(threadId, 'Hello', null);
  launches[0].child.stderr.write('not logged in\n');
  await settle();
  launches[0].child.emit('close', 1);
  await settle();
  assert.equal(events.at(-1).params.turn.status, 'failed');
  assert.match(events.at(-1).params.turn.error.message, /Sign in to Claude Code/);
  await instance.ask(threadId, 'Try again', null);
  assert.equal(launches.length, 2);
});

test('a second question is refused while an answer is in progress', async t => {
  const { instance } = await client(t);
  const threadId = await instance.newThread();
  await instance.ask(threadId, 'First', null);
  await assert.rejects(instance.ask(threadId, 'Second', null), /already in progress/);
});

test('Claude Code offers finished text while writing and withdraws text that precedes a tool', async t => {
  const { instance, launches, events } = await client(t);
  const threadId = await instance.newThread();
  await instance.ask(threadId, 'What does the sign say?', null);
  const child = launches[0].child;
  const stream = event => child.stdout.write(`${JSON.stringify({ type: 'stream_event', event, parent_tool_use_id: null, session_id: threadId })}\n`);
  const text = (index, value) => stream({ type: 'content_block_delta', index, delta: { type: 'text_delta', text: value } });
  stream({ type: 'message_start', message: { role: 'assistant', content: [] } });
  stream({ type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } });
  text(0, 'Let me look. ');
  // A tool call proves the sentence was preparation rather than the answer.
  stream({ type: 'content_block_start', index: 1, content_block: { type: 'tool_use', name: 'Read' } });
  stream({ type: 'message_start', message: { role: 'assistant', content: [] } });
  stream({ type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } });
  text(0, 'The sign says ');
  text(0, 'closed.');
  // Thinking blocks and subagent output are never offered for speech.
  stream({ type: 'content_block_start', index: 1, content_block: { type: 'thinking' } });
  stream({ type: 'content_block_delta', index: 1, delta: { type: 'thinking_delta', thinking: 'hidden' } });
  child.stdout.write(`${JSON.stringify({ type: 'stream_event', parent_tool_use_id: 'sub-1', session_id: threadId, event: { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'subagent' } } })}\n`);
  await settle();
  assert.deepEqual(events.map(event => event.method),
    ['turn/started', 'item/delta', 'item/discarded', 'item/delta', 'item/delta']);
  assert.equal(events[1].params.item.text, 'Let me look. ');
  assert.equal(events[4].params.item.text, 'The sign says closed.');
  answer(child, 'The sign says closed.', threadId);
  await settle();
  assert.equal(events.at(-1).params.turn.status, 'completed');
});

test('Claude Code omits partial output when the installed CLI does not offer it', async t => {
  const { instance, launches } = await client(t, { partialCheck: async () => false });
  await instance.ask(await instance.newThread(), 'Hello', null);
  assert.equal(launches[0].args.includes('--include-partial-messages'), false);
});

test('changing the working folder ends the open conversation', async t => {
  const { instance, launches, directory } = await client(t);
  const threadId = await instance.newThread();
  await instance.ask(threadId, 'Hello', null);
  answer(launches[0].child, 'Hi.', threadId);
  await settle();
  await instance.setWorkspace(`${directory}/..`);
  assert.deepEqual(launches[0].child.kills, ['SIGTERM']);
  await instance.ask(await instance.newThread(), 'Hello again', null);
  assert.equal(launches.length, 2);
  assert.equal(launches[1].options.cwd, instance.workspace);
});

test('Claude runtime candidates prefer the configured executable and standard user path', () => {
  assert.deepEqual(localClaudeCandidates('/bundled/claude', { RAYBRIDGE_CLAUDE: '/forced/claude' }), ['/forced/claude']);
  const candidates = localClaudeCandidates('/bundled/claude', { HOME: '/Users/someone' });
  assert.equal(candidates[0], '/Users/someone/.local/bin/claude');
  assert.ok(candidates.includes('/bundled/claude'));
});

test('the permission mode is unrestricted by default and can be narrowed by environment', () => {
  assert.equal(claudePermissionMode({}), 'bypassPermissions');
  assert.equal(claudePermissionMode({ RAYBRIDGE_CLAUDE_PERMISSION_MODE: 'acceptEdits' }), 'acceptEdits');
});
