// Stage timings for one question, in milliseconds measured from the moment the
// phone's question reached the bridge. Durations only: question text, answer
// text, camera bytes, identifiers, and account details are never recorded.
export class TurnTiming {
  constructor({ now = Date.now, log = message => console.log(message) } = {}) {
    this.now = now;
    this.log = log;
    this.started = now();
    this.marks = new Map();
  }
  // The first mark for a stage wins, so a retried notification cannot move it.
  mark(stage) {
    if (!this.marks.has(stage)) this.marks.set(stage, this.now() - this.started);
    return this;
  }
  summary() {
    const stages = [...this.marks].map(([stage, ms]) => `${stage}=${ms}`).join(' ');
    return `RayBridge turn timing (ms after the question arrived): ${stages || 'none recorded'}`;
  }
  report() {
    if (this.reported) return null;
    this.reported = true;
    const summary = this.summary();
    this.log(summary);
    return summary;
  }
}
