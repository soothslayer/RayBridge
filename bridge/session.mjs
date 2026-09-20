import { TurnTiming } from './timing.mjs';
import { randomUUID } from 'node:crypto';
import { ActionBroker } from './actions.mjs';

export const MAX_FRAME_BYTES = 500_000;
export const FRAME_MAX_AGE_MS = 3500;
export const ACCOUNT_CACHE_MS = 300_000;
// A partial answer is released only at a sentence ending so the phone speaks
// whole sentences while the rest of the answer is still being written.
const SENTENCE_END = /[.!?\u2026]["'\u201d\u2019)\]]*\s|\n+/g;

export function splitSpokenChunk(pending) {
  SENTENCE_END.lastIndex = 0;
  let boundary = 0;
  for (let match = SENTENCE_END.exec(pending); match; match = SENTENCE_END.exec(pending))
    boundary = SENTENCE_END.lastIndex;
  return boundary ? [pending.slice(0, boundary), pending.slice(boundary)] : ['', pending];
}

export function validJPEG(value) {
  if (typeof value !== 'string' || value.length > Math.ceil(MAX_FRAME_BYTES / 3) * 4 ||
      value.length % 4 || !/^[A-Za-z0-9+/]+={0,2}$/.test(value)) return false;
  const bytes = Buffer.from(value, 'base64');
  return bytes.length >= 4 && bytes[0] === 255 && bytes[1] === 216 &&
    bytes.at(-2) === 255 && bytes.at(-1) === 217;
}

// One conversation per authenticated phone connection, one turn at a time.
export class PhoneSession {
  constructor(assistant, send, { now = Date.now, turnTimeout = 90000, tts = null,
    account = null, accountCacheMs = ACCOUNT_CACHE_MS, log, actionBroker = new ActionBroker({ now }) } = {}) {
    this.assistant = assistant; this.send = send; this.now = now; this.turnTimeout = turnTimeout; this.tts = tts;
    this.accountCacheMs = accountCacheMs;
    this.log = log;
    this.sessionId = randomUUID();
    this.connectionEpoch = 1;
    this.actionBroker = actionBroker;
    // The connection handshake already proved the account. Re-reading it for
    // every question costs a CLI subprocess or an extra RPC before the model
    // can even start, so a signed-in result is reused for a short while.
    this.cachedAccount = account?.signedIn ? { account, at: now() } : null;
    this.cancelledTurns = new Set();
    this.listener = message => this.notification(message);
    assistant.on('notification', this.listener);
  }
  async signedInAccount() {
    const cached = this.cachedAccount;
    if (cached && this.now() - cached.at <= this.accountCacheMs) return cached.account;
    const account = await this.assistant.account();
    if (!account.signedIn) {
      this.cachedAccount = null;
      throw new Error(account.signInMessage || 'Sign in to the selected assistant on the Mac first.');
    }
    this.cachedAccount = { account, at: this.now() };
    return account;
  }
  async receive(message) {
    if (this.closed) return;
    switch (message.type) {
      case 'frame':
        if (!validJPEG(message.jpeg)) throw new Error('Camera frame is invalid or too large.');
        if (this.frame && this.now() - this.frame.at < 750) return;
        this.frame = { jpeg: message.jpeg, at: this.now() };
        break;
      case 'camera.off': this.frame = null; break;
      case 'ask': {
        if (this.active || this.starting || this.cancelling) throw new Error('An answer is already in progress.');
        if (typeof message.text !== 'string' || !message.text.trim() || message.text.length > 4000)
          throw new Error('Please ask a question of 1 to 4000 characters.');
        let finishStarting;
        const timing = this.timing = new TurnTiming({ now: this.now,
          ...(this.log ? { log: this.log } : {}) });
        this.starting = new Promise(resolve => { finishStarting = resolve; });
        const generation = this.generation = (this.generation || 0) + 1;
        try {
          await this.signedInAccount();
          timing.mark('account');
          if (this.closed || generation !== this.generation) return;
          const threadId = this.threadId || await this.assistant.newThread();
          timing.mark('conversation');
          if (this.closed || generation !== this.generation) return;
          this.threadId = threadId;
          const frame = this.frame && this.now() - this.frame.at <= FRAME_MAX_AGE_MS ? this.frame.jpeg : null;
          this.active = { text: '', turnId: null, streamed: '', discards: 0, streaming: true,
            ttsEngine: message.ttsEngine === 'kokoro' ? 'kokoro' : 'apple',
            ttsVoice: typeof message.ttsVoice === 'string' ? message.ttsVoice : 'af_heart' };
          this.send({ type: 'thinking', hasImage: !!frame });
          this.timer = setTimeout(() => { this.cancel(); this.send({ type: 'error', message: 'The answer took too long. Please try again.' }); }, this.turnTimeout);
          const result = await this.assistant.ask(threadId, message.text.trim(), frame);
          timing.mark('requestAccepted');
          if (this.closed || generation !== this.generation) {
            if (!this.cancelledTurns.has(result.turn.id)) {
              this.cancelledTurns.add(result.turn.id);
              await this.assistant.call('turn/interrupt', { threadId, turnId: result.turn.id })
                .catch(error => { this.cancelError = error; });
            }
          } else if (this.active) this.active.turnId = result.turn.id;
        } catch (error) {
          // A failure from a cancelled request must not stop the next question.
          if (!this.closed && generation === this.generation) {
            clearTimeout(this.timer); this.active = null; throw error;
          }
        } finally { this.starting = null; finishStarting(); }
        break;
      }
      case 'cancel': {
        const starting = this.starting;
        this.cancelling = true;
        this.cancel();
        try {
          // Acknowledge only when even an in-flight turn/start has settled and
          // its interrupt RPC has completed. The phone can then send a new ask.
          await Promise.all([starting, this.interruption]);
          if (this.cancelError) throw this.cancelError;
          if (!this.closed) this.send({ type: 'cancelled' });
        } finally { this.cancelling = false; }
        break;
      }
      case 'status': await this.coordinatorControl('mac', 'task.status'); break;
      case 'repeat': await this.coordinatorControl('phone', 'speech.repeat'); break;
      case 'reset': this.cancel(); this.threadId = null; this.frame = null; this.send({ type: 'ready' }); break;
      default: throw new Error('Unsupported phone message.');
    }
  }
  notification({ method, params: p }) {
    if (this.closed || !this.active || p?.threadId !== this.threadId) return;
    if (this.cancelledTurns.has(p.turnId || p.turn?.id)) return;
    if (method === 'turn/started') this.active.turnId = p.turn.id;
    if (p.turnId && this.active.turnId && p.turnId !== this.active.turnId) return;
    if (method === 'item/completed' && p.item?.type === 'agentMessage' && p.item.phase !== 'commentary')
      this.active.text = p.item.text;
    // A growing answer is spoken sentence by sentence instead of waiting for the
    // assistant process to finish and exit. The text is always the whole answer
    // so far, so only adapters that promise that send it.
    if (method === 'item/delta' && p.item?.type === 'agentMessage' &&
      p.item.phase !== 'commentary' && typeof p.item.text === 'string')
      this.partialAnswer(p.item.text);
    // The assistant replaced the text it was writing, so anything already spoken
    // was not the answer.
    if (method === 'item/discarded') this.discardPartialAnswer();
    if (method === 'turn/completed') {
      if (this.active.turnId && p.turn.id !== this.active.turnId) return;
      const active = this.active;
      const text = active.text;
      clearTimeout(this.timer); this.active = null;
      this.timing?.mark('answerComplete');
      if (p.turn.status === 'completed' && text) {
        this.lastAnswer = text;
        if (active.ttsEngine === 'kokoro' && this.tts) void this.kokoroAnswer(text, active.ttsVoice, this.generation);
        else { this.send({ type: 'answer', text }); this.timing?.report(); }
      }
      else {
        // A failed turn can mean the assistant was signed out since the handshake.
        this.cachedAccount = null;
        this.timing?.report();
        this.send({ type: 'error', message: p.turn.error?.message || 'The answer was interrupted or empty. Please try again.' });
      }
    }
  }
  async coordinatorControl(device, operation) {
    const action = this.actionBroker.request(this.sessionId, this.connectionEpoch, device, operation);
    const receipt = await this.actionBroker.execute(action, {
      sessionId: this.sessionId, connectionEpoch: this.connectionEpoch, task: null
    }, () => {
      if (operation === 'task.status') {
        if (this.cancelling) return 'Cancellation is still in progress.';
        if (this.starting) return 'The task is starting.';
        if (this.active) return 'The assistant is working on your question.';
        return 'No task is running. RayBridge is listening.';
      }
      return this.lastAnswer || 'There is no completed answer to repeat yet.';
    });
    if (!this.closed) this.send({ type: 'coordinator.speech', text: receipt.result });
  }
  // Partial text is only useful to a phone that speaks it locally. Kokoro
  // generates one audio file on the Mac from the finished answer.
  partialAnswer(text) {
    const active = this.active;
    if (!active || !active.streaming || active.ttsEngine === 'kokoro') return;
    if (!text.startsWith(active.streamed)) return this.discardPartialAnswer();
    const [chunk, rest] = splitSpokenChunk(text.slice(active.streamed.length));
    if (!chunk) return;
    active.streamed = text.slice(0, text.length - rest.length);
    this.timing?.mark('firstSpokenSentence');
    this.send({ type: 'answer.partial', text: chunk });
  }
  discardPartialAnswer() {
    const active = this.active;
    if (!active || !active.streamed) return;
    active.streamed = '';
    // Repeated restarts would stutter, so stop streaming after the second one
    // and let the completed answer be spoken in full.
    active.discards += 1;
    if (active.discards > 2) active.streaming = false;
    this.send({ type: 'answer.discard' });
  }
  async kokoroAnswer(text, voice, generation) {
    try {
      const audio = await this.tts.synthesize(text, voice);
      this.timing?.mark('answerAudio');
      if (!this.closed && generation === this.generation) { this.send({ type: 'answer', text, audio }); this.timing?.report(); }
    } catch (error) {
      this.timing?.mark('answerAudio');
      if (!this.closed && generation === this.generation) {
        this.send({ type: 'answer', text, ttsFallback: error.message || 'Kokoro is unavailable.' });
        this.timing?.report();
      }
    }
  }
  cancel() {
    this.generation = (this.generation || 0) + 1;
    clearTimeout(this.timer);
    this.cancelError = null;
    this.interruption = null;
    if (this.active?.turnId) {
      this.cancelledTurns.add(this.active.turnId);
      this.interruption = this.assistant.call('turn/interrupt', { threadId: this.threadId, turnId: this.active.turnId })
        .catch(error => { this.cancelError = error; });
    }
    this.active = null;
  }
  close() { this.closed = true; this.cancel(); this.frame = null; this.assistant.off('notification', this.listener); }
}
