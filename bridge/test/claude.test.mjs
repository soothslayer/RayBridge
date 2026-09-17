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
