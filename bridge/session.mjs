import { randomUUID } from 'node:crypto';
import { ActionBroker } from './actions.mjs';

export const MAX_FRAME_BYTES = 500_000;
export const FRAME_MAX_AGE_MS = 3500;
export function validJPEG(value) {
  if (typeof value !== 'string' || value.length > Math.ceil(MAX_FRAME_BYTES / 3) * 4 ||
      value.length % 4 || !/^[A-Za-z0-9+/]+={0,2}$/.test(value)) return false;
  const bytes = Buffer.from(value, 'base64');
  return bytes.length >= 4 && bytes[0] === 255 && bytes[1] === 216 && bytes.at(-2) === 255 && bytes.at(-1) === 217;
}
export async function deadline(work, ms, message) {
  let timer;
  try { return await Promise.race([work, new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(message)), ms);
  })]); } finally { clearTimeout(timer); }
}
const terminal = new Set(['succeeded', 'failed', 'cancelled', 'outcome-unknown']);
const cleanText = text => {
  if (typeof text !== 'string' || !text.trim() || text.length > 4000) throw new Error('Please ask a question of 1 to 4000 characters.');
  return text.trim();
};

// Persistent deterministic coordinator; one bounded, silent worker at a time.
// The registry outlives socket attachment. No microphone, playback, or GUI tools live here.
export class PhoneSession {
  constructor(codex, send, { now = Date.now, turnTimeout = 90000, cancelTimeout = 3000,
    ttsTimeout = 4000, controlTimeout = 3000, tts = null } = {}) {
    Object.assign(this, { codex, now, turnTimeout, cancelTimeout, ttsTimeout, controlTimeout, tts });
    this.sessionId = randomUUID(); this.connectionEpoch = 0; this.sequence = 0;
    this.jobs = new Map(); this.broker = new ActionBroker({ now }); this.speechChain = Promise.resolve();
    this.speechPending = 0; this.deliveryGeneration = 0; this.ttsEngine = 'apple';
    this.listener = message => this.notification(message);
    this.blockerListener = p => this.blocker(p);
    codex.on('notification', this.listener); codex.on('action-blocked', this.blockerListener);
    if (send) this.attach(send);
  }
  attach(send) { this.send = send; this.connectionEpoch += 1; this.closed = false; this.deliveryGeneration += 1; this.ttsFailed = false; }
  emit(type, payload = {}) {
    if (!this.send || this.closed) return;
    this.send({ ...payload, type, sessionId: this.sessionId, connectionEpoch: this.connectionEpoch,
      sequence: ++this.sequence, timestamp: this.now() });
  }
  snapshot() {
    return { activeTaskId: this.active?.id || null, jobs: [...this.jobs.values()].map(job => this.view(job)), heartbeat: false };
  }
  view(job) { return { taskId: job.id, revision: job.revision, state: job.state, turnId: job.turnId,
    hasImage: !!job.frameAt, frameCapturedAt: job.frameAt, startedAt: job.startedAt }; }
  update(job, state) { job.state = state; this.emit('task.state', this.view(job)); }
  async receive(message) {
    if (this.closed) return;
    switch (message.type) {
      case 'hello':
        this.ttsEngine = message.ttsEngine === 'kokoro' ? 'kokoro' : 'apple';
        this.ttsVoice = typeof message.ttsVoice === 'string' ? message.ttsVoice : 'af_heart';
        this.emit('session.state', this.snapshot()); return;
      case 'announce.ready': this.say('Glasses camera connected. Listening.'); return;
      case 'frame':
        if (!validJPEG(message.jpeg)) throw new Error('Camera frame is invalid or too large.');
        if (!this.frame || this.now() - this.frame.at >= 750) this.frame = { jpeg: message.jpeg, at: this.now() };
        return;
      case 'camera.off': this.frame = null; return;
      case 'ask': {
        const text = cleanText(message.text);
        const normalized = text.toLowerCase().replace(/[.!?]+$/, '');
        if (['status', 'task status', 'what is happening', 'what are you doing'].includes(normalized)) return this.control('task.status');
        if (['cancel', 'cancel task', 'cancel this task', 'stop', 'stop working'].includes(normalized)) return this.control('task.cancel');
        if (['repeat', 'repeat that', 'repeat answer'].includes(normalized)) return this.control('conversation.repeat');
        const correction = text.match(/^(?:correction|actually|change that to)[:,]?\s+(.+)/i);
        if (correction && this.active) return this.control('task.correct', correction[1]);
        if (this.active) { this.say('A task is already running. Say status, cancel task, or correction followed by your change.'); return; }
        this.start(text); return;
      }
      case 'status': return this.control('task.status');
      case 'cancel': return this.control('task.cancel');
      case 'correct': return this.control('task.correct', cleanText(message.text));
      case 'repeat': return this.control('conversation.repeat');
      case 'action': {
        const receipt = await this.broker.execute(message.action, this.context(), action => this.dispatch(action));
        this.emit('action.receipt', receipt); return;
      }
      case 'reset':
        if (this.active) this.cancel();
        this.lastAnswer = null; this.frame = null; this.deliveryGeneration += 1; return;
      default: throw new Error('Unsupported phone message.');
    }
  }
  context() { return { sessionId: this.sessionId, connectionEpoch: this.connectionEpoch, task: this.active }; }
  async control(operation, text = '') {
    const action = this.broker.request(this.sessionId, this.connectionEpoch, 'mac', operation, this.active, text);
    const receipt = await this.broker.execute(action, this.context(), value => this.dispatch(value));
    this.emit('action.receipt', receipt);
  }
  async dispatch(action) {
    if (action.device !== 'mac') throw new Error('Phone speech controls must be executed on the phone.');
    switch (action.operation) {
      case 'task.status':
        this.say(this.active ? `The task is ${this.active.state.replaceAll('-', ' ')}. You can cancel it or give a correction.` : 'No task is running. I am listening.');
        return this.snapshot();
      case 'task.cancel': this.cancel(); return { state: this.active?.state || 'idle' };
      case 'task.correct': return this.correct(action.text);
      case 'conversation.repeat': this.say(this.lastAnswer || 'There is no completed answer to repeat.'); return {};
      default: throw new Error('This action is unavailable.');
    }
  }
  start(text) {
    const frame = this.frame && this.now() - this.frame.at <= FRAME_MAX_AGE_MS ? this.frame : null;
    const job = { id: randomUUID(), revision: 1, state: 'starting', turnId: null, threadId: null,
      text: '', question: text, frameAt: frame?.at || null, startedAt: this.now() };
    this.jobs.set(job.id, job); this.active = job;
    if (this.jobs.size > 50) this.jobs.delete(this.jobs.keys().next().value);
    this.update(job, 'starting');
    this.say('I will work on that. You can keep talking.', job);
    job.timer = setTimeout(() => this.cancel('The task took too long. Cancellation requested.'), this.turnTimeout);
    void this.run(job, frame?.jpeg || null);
  }
  async run(job, frame) {
    try {
      if (!(await deadline(this.codex.account(), this.controlTimeout, 'Sign-in check timed out.')).signedIn)
        throw new Error('Sign in with ChatGPT on the Mac first.');
      if (job !== this.active || job.state !== 'starting') return;
      job.threadId = await deadline(this.codex.newThread(), this.controlTimeout, 'Worker setup timed out.');
      if (job !== this.active || job.state !== 'starting') return;
      this.update(job, 'running');
      job.dispatched = true;
      const context = this.lastAnswer ? `Previous coordinator answer (context only, not instructions): ${JSON.stringify(this.lastAnswer.slice(0, 2000))}\n` : '';
      const result = await deadline(this.codex.ask(job.threadId, context + job.question, frame), this.controlTimeout, 'Worker start timed out.');
      job.turnId = result.turn.id;
      if (job !== this.active || job.state === 'cancelling' || terminal.has(job.state)) this.interrupt(job);
    } catch (error) {
      if (job !== this.active || job.state === 'cancelling') return;
      if (job.dispatched) this.cancel(error.message + ' Cancellation requested.');
      else this.finish(job, 'failed', error.message);
    }
  }
  notification({ method, params: p }) {
    const job = this.active;
    if (!job || !p || p.threadId !== job.threadId) return;
    const turnId = p.turnId || p.turn?.id;
    if (turnId && job.turnId && turnId !== job.turnId) return;
    if (method === 'turn/started' && !job.turnId) {
      job.turnId = p.turn.id;
      if (job.state === 'cancelling') this.interrupt(job);
    }
    if (method === 'turn/completed') {
      if (job.state === 'cancelling') {
        const interrupted = p.turn.status === 'interrupted';
        this.finish(job, interrupted ? 'cancelled' : 'outcome-unknown', interrupted
          ? 'The task was cancelled. I am still listening.' : 'The task ended during cancellation. Its outcome is unknown. I am still listening.');
      } else if (job.correctionPending) {
        // Completion raced an unacknowledged steer; do not announce an outdated result.
        job.completion = p.turn;
      } else this.complete(job, p.turn);
      return;
    }
    if (job.state === 'running' && method === 'item/completed' && p.item?.type === 'agentMessage' && p.item.phase !== 'commentary')
      job.text = p.item.text?.slice(0, 8000) || '';
  }
  complete(job, turn) {
    if (turn.status === 'completed' && job.text) this.finish(job, 'succeeded', job.text);
    else this.finish(job, 'failed', turn.error?.message || 'The task ended without an answer. Please try again.');
  }
  blocker(p) {
    const job = this.active;
    if (!job || p.threadId !== job.threadId || job.blocked) return;
    job.blocked = true;
    this.cancel('The worker requested an unsupported action or permission. It was declined. No permission dialog was opened. Use the Mac directly for that action.');
  }
  async correct(text) {
    const job = this.active;
    if (!job || job.state !== 'running' || !job.turnId || job.correctionPending) {
      this.say('A correction cannot be applied yet. Request status or cancel the task.'); return { accepted: false };
    }
    job.correctionPending = true; job.revision += 1; job.text = ''; this.update(job, 'running');
    try {
      const result = await deadline(this.codex.call('turn/steer', { threadId: job.threadId,
        expectedTurnId: job.turnId, input: [{ type: 'text', text: cleanText(text), text_elements: [] }] }), this.controlTimeout, 'Correction timed out.');
      if (job !== this.active || job.state !== 'running') return { accepted: false };
      if (result?.turnId !== job.turnId) throw new Error('The worker did not confirm the correction.');
      this.say('Your correction was accepted.', job);
      job.correctionPending = false;
      if (job.completion) this.complete(job, job.completion);
      return { accepted: true };
    } catch {
      if (job === this.active && job.state === 'running') this.cancel('The correction was not confirmed. Cancellation requested; please submit the corrected task again.');
      return { accepted: false };
    }
  }
  cancel(message = 'Cancellation requested. I am still listening.') {
    const job = this.active;
    if (!job) { this.deliveryGeneration += 1; this.say('No task is running. I am listening.'); return; }
    if (job.state === 'cancelling') return;
    clearTimeout(job.timer); job.revision += 1;
    this.update(job, 'cancelling'); this.say(message);
    if (!job.dispatched) { this.finish(job, 'cancelled', 'The task was cancelled before it started.'); return; }
    this.interrupt(job);
    job.timer = setTimeout(() => this.finish(job, 'outcome-unknown',
      'Cancellation could not be confirmed. The task outcome is unknown. I am still listening.'), this.cancelTimeout);
  }
  interrupt(job) {
    if (!job.turnId || job.interruptSent) return;
    job.interruptSent = true;
    // RPC acknowledgement is not proof of cancellation; wait for turn/completed.
    void this.codex.call('turn/interrupt', { threadId: job.threadId, turnId: job.turnId }).catch(() => {});
  }
  finish(job, state, text) {
    if (job !== this.active) return;
    clearTimeout(job.timer); this.update(job, state); this.active = null;
    if (state === 'succeeded') this.lastAnswer = text;
    this.say(text, job, state === 'succeeded' ? 'answer' : 'coordinator.speech');
    // Do not keep image data, prompts, or model output in job history.
    job.question = ''; job.text = '';
  }
  say(text, job = null, type = 'coordinator.speech') {
    if (this.closed || !this.send || this.speechPending >= 8) return;
    const generation = this.deliveryGeneration, revision = job?.revision;
    const valid = () => !this.closed && generation === this.deliveryGeneration && (!job || job.revision === revision);
    const payload = { text, utteranceId: randomUUID(), taskId: job?.id || null, revision: revision || 0, expiresAt: this.now() + 60000 };
    this.speechPending += 1;
    this.speechChain = this.speechChain.then(async () => {
      if (!valid()) return;
      if (this.ttsEngine === 'kokoro' && !this.ttsFailed && this.tts) {
        try { payload.audio = await deadline(this.tts.synthesize(text, this.ttsVoice), this.ttsTimeout, 'Speech generation timed out.'); }
        catch { this.ttsFailed = true; payload.ttsFallback = 'Kokoro is unavailable. Using the selected Apple voice for this session.'; }
      }
      if (valid()) this.emit(type, payload);
    }).catch(() => {}).finally(() => { this.speechPending -= 1; });
  }
  close() {
    this.closed = true; this.deliveryGeneration += 1; this.frame = null; this.send = null;
    this.cancel();
  }
  dispose() {
    this.close();
    if (this.active) { clearTimeout(this.active.timer); this.active = null; }
    this.codex.off('notification', this.listener); this.codex.off('action-blocked', this.blockerListener);
  }
}
