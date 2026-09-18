import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { HermesClient, localHermesCandidates } from '../hermes.mjs';

class FakeChild extends EventEmitter {
  stdin = new PassThrough();
  stdout = new PassThrough();
  stderr = new PassThrough();
  exitCode = null;
  kills = [];
  kill(signal) {
    this.kills.push(signal);
    queueMicrotask(() => { this.exitCode = 0; this.emit('close', null, signal); });
    return true;
  }
}

test('Hermes uses a private named conversation, stdin prompt, and attached camera image', async t => {
  const directory = await mkdtemp('/tmp/raybridge-hermes-test-');
  t.after(() => rm(directory, { recursive: true, force: true }));
  const launches = [];
  const client = new HermesClient(`${directory}/frames`, '/test/hermes', directory, {
    versionCheck: async executable => executable === '/test/hermes' ? 'Hermes Agent v1.0' : null,
    spawnProcess: (executable, args, options) => {
      const child = new FakeChild(); launches.push({ executable, args, options, child }); return child;
    }
  });
  await client.start();
  assert.deepEqual(await client.account(), { signedIn: true, plan: 'v1.0' });
  const events = [];
  client.on('notification', event => events.push(event));
  const threadId = await client.newThread();
  const jpeg = Buffer.from([255, 216, 0, 255, 217]).toString('base64');
  const first = await client.ask(threadId, 'What is this?', jpeg);
  assert.equal(launches[0].executable, '/test/hermes');
  assert.equal(launches[0].options.cwd, client.workspace);
  assert.equal(launches[0].options.detached, true);
  assert.deepEqual(launches[0].args.slice(0, 5), ['chat', '--query-file', '-', '--oneshot', '--quiet']);
  assert.ok(launches[0].args.includes('--create-if-missing'));
  assert.ok(launches[0].args.includes(`raybridge-${threadId}`));
  assert.ok(launches[0].args.includes('--image'));
  assert.equal(launches[0].args.some(argument => argument.includes('What is this?')), false);
  const framePath = launches[0].args.at(-1);
  assert.deepEqual(await readFile(framePath), Buffer.from(jpeg, 'base64'));
  const prompt = launches[0].child.stdin.read().toString();
  assert.ok(prompt.includes('User request:\nWhat is this?'));
  assert.ok(prompt.includes('current camera image'));
  launches[0].child.stdout.write('A blue chair.\n');
  launches[0].child.exitCode = 0;
  launches[0].child.emit('close', 0);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(events.map(x => x.method), ['turn/started', 'item/completed', 'turn/completed']);
  assert.equal(events[1].params.item.text, 'A blue chair.');
  assert.equal(events[2].params.turn.status, 'completed');
  const second = await client.ask(threadId, 'And now?', null);
  assert.ok(launches[1].args.includes(`raybridge-${threadId}`));
  assert.ok(!launches[1].args.includes('--image'));
  assert.notEqual(first.turn.id, second.turn.id);
  launches[1].child.stdout.write('Still there.\n');
  launches[1].child.exitCode = 0;
  launches[1].child.emit('close', 0);
});

test('Hermes interruption terminates the active process', async t => {
  const directory = await mkdtemp('/tmp/raybridge-hermes-cancel-');
  t.after(() => rm(directory, { recursive: true, force: true }));
  let child;
  const client = new HermesClient(`${directory}/frames`, '/test/hermes', directory, {
    versionCheck: async () => 'Hermes Agent v1.0',
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

test('Hermes runtime candidates prefer the configured executable and standard user path', () => {
  assert.deepEqual(localHermesCandidates('hermes', { HOME: '/Users/test', RAYBRIDGE_HERMES: '/chosen/hermes' }), ['/chosen/hermes']);
  const candidates = localHermesCandidates('hermes', { HOME: '/Users/test' });
  assert.equal(candidates[0], '/Users/test/.local/bin/hermes');
  assert.equal(candidates.at(-1), 'hermes');
});
