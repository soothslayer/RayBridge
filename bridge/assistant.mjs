import { EventEmitter } from 'node:events';

export const assistantProviders = new Set(['codex', 'claude']);

// Presents every assistant backend through the event and method contract used
// by PhoneSession. Switching providers stops the old backend before starting
// the new one, so a conversation can never straddle two assistants.
export class AssistantRouter extends EventEmitter {
  constructor(clients, provider = 'codex') {
    super();
    if (!assistantProviders.has(provider) || !clients?.[provider]) throw new Error('Choose a valid assistant provider.');
    this.clients = clients;
    this.provider = provider;
    for (const [name, client] of Object.entries(clients)) {
      client.on('notification', message => { if (name === this.provider) this.emit('notification', message); });
      client.on('unavailable', error => { if (name === this.provider) this.emit('unavailable', error); });
    }
  }
  get current() { return this.clients[this.provider]; }
  get accountSource() { return this.current.accountSource; }
  get workspace() { return this.current.workspace; }
  async start() { await this.current.start(); }
  stop() { this.current.stop(); }
  async setProvider(provider) {
    if (!assistantProviders.has(provider) || !this.clients[provider]) throw new Error('Choose a valid assistant provider.');
    if (provider === this.provider) return;
    const previousProvider = this.provider;
    const previous = this.current;
    previous.stop();
    this.provider = provider;
    try {
      await this.current.start();
    } catch (error) {
      this.current.stop();
      this.provider = previousProvider;
      try { await previous.start(); } catch {}
      throw error;
    }
  }
  async account() {
    const account = await this.current.account();
    return { ...account, provider: this.provider,
      signInMessage: account.signInMessage || (this.provider === 'claude'
        ? 'Sign in to Claude Code on the Mac first.' : 'Sign in with ChatGPT on the Mac first.') };
  }
  newThread() { return this.current.newThread(); }
  ask(threadId, question, frame) { return this.current.ask(threadId, question, frame); }
  call(method, params) { return this.current.call(method, params); }
  setAccountSource(source) {
    if (typeof this.current.setAccountSource !== 'function') throw new Error('Account selection is unavailable for this assistant.');
    return this.current.setAccountSource(source);
  }
  setWorkspace(workspace) {
    if (typeof this.current.setWorkspace !== 'function') throw new Error('Workspace selection is unavailable for this assistant.');
    return this.current.setWorkspace(workspace);
  }
  setAllowedApps(apps) {
    if (typeof this.current.setAllowedApps !== 'function') throw new Error('App selection is unavailable for this assistant.');
    return this.current.setAllowedApps(apps);
  }
}
