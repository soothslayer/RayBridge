export const MAX_FRAME_BYTES = 500_000;
export const FRAME_MAX_AGE_MS = 3500;

export function validJPEG(value) {
  if (typeof value !== 'string' || value.length > Math.ceil(MAX_FRAME_BYTES / 3) * 4 ||
      value.length % 4 || !/^[A-Za-z0-9+/]+={0,2}$/.test(value)) return false;
  const bytes = Buffer.from(value, 'base64');
  return bytes.length >= 4 && bytes[0] === 255 && bytes[1] === 216 &&
    bytes.at(-2) === 255 && bytes.at(-1) === 217;
}

// One conversation per authenticated phone connection, one turn at a time.
export class PhoneSession {
  constructor(codex, send, { now = Date.now, turnTimeout = 90000 } = {}) {
    this.codex = codex; this.send = send; this.now = now; this.turnTimeout = turnTimeout;
    this.cancelledTurns = new Set();
    this.listener = message => this.notification(message);
    codex.on('notification', this.listener);
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
        if (this.active || this.starting) throw new Error('An answer is already in progress.');
        if (typeof message.text !== 'string' || !message.text.trim() || message.text.length > 4000)
          throw new Error('Please ask a question of 1 to 4000 characters.');
        this.starting = true;
        const generation = this.generation = (this.generation || 0) + 1;
        try {
          if (!(await this.codex.account()).signedIn) throw new Error('Sign in with ChatGPT on the Mac first.');
          const threadId = this.threadId || await this.codex.newThread();
          if (this.closed || generation !== this.generation) return;
          this.threadId = threadId;
          const frame = this.frame && this.now() - this.frame.at <= FRAME_MAX_AGE_MS ? this.frame.jpeg : null;
          if (message.requiresImage === true && !frame) {
            const error = new Error('No current camera image reached the Mac. Reconnect the camera and ask again.');
            error.code = 'camera_unavailable';
            throw error;
          }
          this.active = { text: '', turnId: null };
          this.send({ type: 'thinking', hasImage: !!frame });
          this.timer = setTimeout(() => { this.cancel(); this.send({ type: 'error', message: 'The answer took too long. Please try again.' }); }, this.turnTimeout);
          const result = await this.codex.ask(threadId, message.text.trim(), frame);
          if (this.closed || generation !== this.generation) {
            this.cancelledTurns.add(result.turn.id);
            await this.codex.call('turn/interrupt', { threadId, turnId: result.turn.id }).catch(() => {});
          } else if (this.active) this.active.turnId = result.turn.id;
        } catch (error) { clearTimeout(this.timer); this.active = null; throw error; }
        finally { this.starting = false; }
        break;
      }
      case 'cancel': this.cancel(); this.send({ type: 'cancelled' }); break;
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
    if (method === 'turn/completed') {
      if (this.active.turnId && p.turn.id !== this.active.turnId) return;
      const text = this.active.text;
      clearTimeout(this.timer); this.active = null;
      if (p.turn.status === 'completed' && text) this.send({ type: 'answer', text });
      else this.send({ type: 'error', message: p.turn.error?.message || 'The answer was interrupted or empty. Please try again.' });
    }
  }
  cancel() {
    this.generation = (this.generation || 0) + 1;
    clearTimeout(this.timer);
    if (this.active?.turnId) {
      this.cancelledTurns.add(this.active.turnId);
      this.codex.call('turn/interrupt', { threadId: this.threadId, turnId: this.active.turnId }).catch(() => {});
    }
    this.active = null;
  }
  close() { this.closed = true; this.cancel(); this.frame = null; this.codex.off('notification', this.listener); }
}
