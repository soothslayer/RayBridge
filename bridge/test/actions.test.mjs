import test from 'node:test';
import assert from 'node:assert/strict';
import { ActionBroker } from '../actions.mjs';

function setup() {
  let time = 1000;
  const broker = new ActionBroker({ now: () => time });
  const context = { sessionId: 'session-1', connectionEpoch: 2, task: { id: 'task-1', revision: 3 } };
  const action = broker.request('session-1', 2, 'mac', 'task.status', context.task);
  return { broker, context, action, advance: milliseconds => { time += milliseconds; } };
}

test('creates a short-lived action scoped to the session, connection, and task', () => {
  const { action } = setup();
  assert.equal(action.sessionId, 'session-1');
  assert.equal(action.connectionEpoch, 2);
  assert.equal(action.taskId, 'task-1');
  assert.equal(action.revision, 3);
  assert.equal(action.expiresAt, 11000);
  assert.match(action.actionId, /^[0-9a-f-]{36}$/);
});

test('executes the same action once and returns the same receipt', async () => {
  const { broker, context, action } = setup();
  let calls = 0;
  const dispatch = async () => { calls += 1; return 'working'; };
  const first = await broker.execute(action, context, dispatch);
  const second = await broker.execute(action, context, dispatch);
  assert.equal(calls, 1);
  assert.deepEqual(second, first);
  assert.equal(first.outcome, 'completed');
  assert.equal(first.result, 'working');
});

test('rejects changed, expired, unscoped, stale, and unsupported actions', async () => {
  const cases = [
    ({ action }) => ({ ...action, sessionId: 'other' }),
    ({ action }) => ({ ...action, connectionEpoch: 9 }),
    ({ action }) => ({ ...action, taskId: 'old-task' }),
    ({ action }) => ({ ...action, operation: 'shell.run' }),
    ({ action }) => ({ ...action, extra: true })
  ];
  for (const mutate of cases) {
    const state = setup();
    await assert.rejects(state.broker.execute(mutate(state), state.context, () => 'no'),
      /Unsupported|task changed/);
  }
  const expired = setup();
  expired.advance(10001);
  await assert.rejects(expired.broker.execute(expired.action, expired.context, () => 'no'), /expired/);

  const changed = setup();
  await changed.broker.execute(changed.action, changed.context, () => 'done');
  await assert.rejects(changed.broker.execute({ ...changed.action, text: 'changed' }, changed.context, () => 'no'),
    /content changed/);
});

test('bounds remembered action receipts', async () => {
  const { broker } = setup();
  for (let index = 0; index < 140; index += 1) {
    const action = broker.request('session-1', 2, 'phone', 'speech.repeat');
    await broker.execute(action, { sessionId: 'session-1', connectionEpoch: 2, task: null }, () => index);
  }
  assert.equal(broker.receipts.size, 128);
});
