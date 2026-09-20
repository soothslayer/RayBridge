import { randomUUID } from 'node:crypto';

// The paired coordinator is the only caller. Workers have no action transport.
export const actionCapabilities = Object.freeze({
  mac: ['task.status', 'task.cancel', 'task.correct', 'conversation.repeat'],
  phone: ['speech.stop', 'speech.repeat']
});

export class ActionBroker {
  constructor({ now = Date.now } = {}) { this.now = now; this.receipts = new Map(); }
  request(sessionId, epoch, device, operation, task = null, text = '') {
    return { actionId: randomUUID(), sessionId, connectionEpoch: epoch, device, operation,
      taskId: task?.id || null, revision: task?.revision || 0, expiresAt: this.now() + 10000, text };
  }
  async execute(action, context, dispatch) {
    if (!action || typeof action.actionId !== 'string' || action.actionId.length > 100 ||
        action.sessionId !== context.sessionId || action.connectionEpoch !== context.connectionEpoch ||
        !Number.isFinite(action.expiresAt) || action.expiresAt <= this.now() || action.expiresAt > this.now() + 10000 ||
        !actionCapabilities[action.device]?.includes(action.operation) ||
        typeof action.text !== 'string' || action.text.length > 4000 ||
        Object.keys(action).some(key => !['actionId', 'sessionId', 'connectionEpoch', 'device', 'operation', 'taskId', 'revision', 'expiresAt', 'text'].includes(key)))
      throw new Error('Unsupported or expired action. Use the RayBridge task or speech controls.');
    const fingerprint = JSON.stringify(action);
    const previous = this.receipts.get(action.actionId);
    if (previous) {
      if (previous.fingerprint !== fingerprint) throw new Error('Action content changed. Submit a new action.');
      return previous.promise;
    }
    if (action.taskId !== (context.task?.id || null) || action.revision !== (context.task?.revision || 0))
      throw new Error('The task changed. Request status before trying again.');
    const promise = Promise.resolve().then(() => dispatch(action)).then(result =>
      ({ actionId: action.actionId, device: action.device, operation: action.operation, outcome: 'completed', result }));
    this.receipts.set(action.actionId, { fingerprint, promise });
    // Requests expire before they can become executable again; keep a bounded receipt cache.
    if (this.receipts.size > 128) this.receipts.delete(this.receipts.keys().next().value);
    return promise;
  }
}
