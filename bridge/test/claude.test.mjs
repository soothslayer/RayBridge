import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { ClaudeClient, localClaudeCandidates } from '../claude.mjs';

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

test('Claude Code streams a final answer, resumes the conversation, and stages camera images privately', async t => {
  const directory = await mkdtemp('/tmp/raybridge-claude-test-');
  t.after(() => rm(directory, { recursive: true, force: true }));
  const launches = [];
  const client = new ClaudeClient(`${directory}/frames`, '/test/claude', directory, {
    versionCheck: async executable => executable === '/test/claude',
    spawnProcess: (executable, args, options) => {
      const child = new FakeChild(); launches.push({ executable, args, options, child }); return child;
    }
  });
  await client.start();
  const events = [];
  client.on('notification', event => events.push(event));
  const threadId = await client.newThread();
  const jpeg = Buffer.from([255, 216, 0, 255, 217]).toString('base64');
  const first = await client.ask(threadId, 'What is this?', jpeg);
  assert.equal(launches[0].executable, '/test/claude');
  assert.equal(launches[0].options.cwd, client.workspace);
  assert.ok(launches[0].args.includes('--session-id'));
  assert.ok(launches[0].args.includes('--permission-prompts'));
  const prompt = launches[0].child.stdin.read().toString();
  assert.ok(prompt.includes('current camera image'));
  assert.equal(launches[0].args.some(argument => argument.includes('What is this?')), false);
  const framePath = prompt.match(/at (.+\.jpg)\. Use/)[1];
  assert.deepEqual(await readFile(framePath), Buffer.from(jpeg, 'base64'));
  launches[0].child.stdout.write(`${JSON.stringify({ type: 'system', session_id: threadId })}\n`);
  launches[0].child.stdout.write(`${JSON.stringify({ type: 'assistant', message: { content: [{ type: 'text', text: 'A blue chair.' }] } })}\n`);
  launches[0].child.stdout.write(`${JSON.stringify({ type: 'result', subtype: 'success', result: 'A blue chair.', session_id: threadId })}\n`);
  launches[0].child.emit('close', 0);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(events.map(x => x.method), ['turn/started', 'item/completed', 'turn/completed']);
  assert.equal(events[1].params.item.text, 'A blue chair.');
  assert.equal(events[2].params.turn.status, 'completed');
  const second = await client.ask(threadId, 'And now?', null);
  assert.ok(launches[1].args.includes('--resume'));
  assert.ok(!launches[1].args.includes('--session-id'));
  assert.notEqual(first.turn.id, second.turn.id);
  launches[1].child.stdout.write(`${JSON.stringify({ type: 'result', result: 'Still there.', session_id: threadId })}\n`);
  launches[1].child.emit('close', 0);
});

test('Claude Code interruption terminates the active process and reports an interrupted turn', async t => {
  const directory = await mkdtemp('/tmp/raybridge-claude-cancel-');
  t.after(() => rm(directory, { recursive: true, force: true }));
  let child;
  const client = new ClaudeClient(`${directory}/frames`, '/test/claude', directory, {
    versionCheck: async () => true,
    spawnProcess: () => (child = new FakeChild())
  });
  await client.start();
  const events = [];
  client.on('notification', event => events.push(event));
  const threadId = await client.newThread();
  const { turn } = await client.ask(threadId, 'Stop this', null);
  await client.call('turn/interrupt', { threadId, turnId: turn.id });
  assert.deepEqual(child.kills, ['SIGTERM']);
  assert.equal(events.at(-1).params.turn.status, 'interrupted');
});

test('Claude runtime candidates prefer the configured executable and standard user path', () => {
  assert.deepEqual(localClaudeCandidates('claude', { HOME: '/Users/test', RAYBRIDGE_CLAUDE: '/chosen/claude' }), ['/chosen/claude']);
  const candidates = localClaudeCandidates('claude', { HOME: '/Users/test' });
  assert.equal(candidates[0], '/Users/test/.local/bin/claude');
  assert.equal(candidates.at(-1), 'claude');
});

test('Claude Code offers finished text while writing and withdraws text that precedes a tool', async t => {
  const directory = await mkdtemp('/tmp/raybridge-claude-stream-');
  t.after(() => rm(directory, { recursive: true, force: true }));
  let child;
  const client = new ClaudeClient(`${directory}/frames`, '/test/claude', directory, {
    versionCheck: async () => true,
    partialCheck: async () => true,
    spawnProcess: (executable, args) => { client.launchedArgs = args; return (child = new FakeChild()); }
  });
  await client.start();
  const events = [];
  client.on('notification', event => events.push(event));
  const threadId = await client.newThread();
  await client.ask(threadId, 'What does the sign say?', null);
  assert.ok(client.launchedArgs.includes('--include-partial-messages'));
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
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(events.map(event => event.method),
    ['turn/started', 'item/delta', 'item/discarded', 'item/delta', 'item/delta']);
  assert.equal(events[1].params.item.text, 'Let me look. ');
  assert.equal(events[3].params.item.text, 'The sign says ');
  assert.equal(events[4].params.item.text, 'The sign says closed.');
  child.stdout.write(`${JSON.stringify({ type: 'result', result: 'The sign says closed.', session_id: threadId })}\n`);
  child.emit('close', 0);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(events.at(-2).params.item.text, 'The sign says closed.');
  assert.equal(events.at(-1).params.turn.status, 'completed');
});

test('Claude Code omits partial output when the installed CLI does not offer it', async t => {
  const directory = await mkdtemp('/tmp/raybridge-claude-nopartial-');
  t.after(() => rm(directory, { recursive: true, force: true }));
  let launched;
  const client = new ClaudeClient(`${directory}/frames`, '/test/claude', directory, {
    versionCheck: async () => true,
    partialCheck: async () => false,
    spawnProcess: (executable, args) => { launched = args; return new FakeChild(); }
  });
  await client.start();
  await client.ask(await client.newThread(), 'Hello', null);
  assert.equal(launched.includes('--include-partial-messages'), false);
});
