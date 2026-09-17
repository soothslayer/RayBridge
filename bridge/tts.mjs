import os from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { access, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';

const execFileAsync = promisify(execFile);
const MODEL_ID = 'onnx-community/Kokoro-82M-v1.0-ONNX';
const DEFAULT_VOICE = 'af_heart';
const MAX_AUDIO_BYTES = 8 * 1024 * 1024;

export const kokoroVoices = new Set([
  'af_heart', 'af_bella', 'af_nova', 'af_sarah', 'af_sky',
  'am_fenrir', 'am_michael', 'am_puck',
  'bf_emma', 'bf_isabella', 'bm_daniel', 'bm_george'
]);

async function loadKokoro(cacheDir, allowDownload, progress) {
  const [{ env }, { KokoroTTS }] = await Promise.all([
    import('@huggingface/transformers'), import('kokoro-js')
  ]);
  env.cacheDir = cacheDir;
  env.allowLocalModels = true;
  env.allowRemoteModels = allowDownload;
  return KokoroTTS.from_pretrained(MODEL_ID, {
    dtype: 'q4',
    device: 'cpu',
    progress_callback: progress
  });
}

async function aacFromWav(wav) {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'raybridge-kokoro-'));
  const input = path.join(directory, 'speech.wav');
  const output = path.join(directory, 'speech.m4a');
  try {
    await writeFile(input, wav);
    await execFileAsync('/usr/bin/afconvert', ['-f', 'm4af', '-d', 'aac', '-b', '64000', input, output],
      { timeout: 120000, maxBuffer: 1024 * 1024 });
    const audio = await readFile(output);
    if (!audio.length || audio.length > MAX_AUDIO_BYTES) throw new Error('The generated answer audio is too large.');
    return audio;
  } finally { await rm(directory, { recursive: true, force: true }); }
}

export class KokoroService {
  constructor(dataDir, { loader = loadKokoro, converter = aacFromWav } = {}) {
    this.directory = path.join(dataDir, 'kokoro');
    this.cacheDir = path.join(this.directory, 'models');
    this.marker = path.join(this.directory, 'ready');
    this.loader = loader;
    this.converter = converter;
    this.detail = 'Kokoro has not been downloaded.';
    this.progress = null;
  }

  async installed() {
    if (this.model) return true;
    try { await access(this.marker); return true; } catch { return false; }
  }

  async status() {
    const installed = await this.installed();
    if (installed && !this.installPromise && !this.error) this.detail = 'Kokoro is ready for iPhone answers.';
    return {
      installed,
      installing: !!this.installPromise,
      progress: this.progress,
      detail: this.detail,
      error: this.error || null
    };
  }

  async startInstall() {
    if (await this.installed()) {
      this.error = null;
      this.detail = 'Kokoro is ready for iPhone answers.';
      return this.status();
    }
    if (!this.installPromise) {
      this.error = null;
      this.progress = 0;
      this.detail = 'Starting the Kokoro download…';
      this.installPromise = this.load(true)
        .then(async () => {
          await mkdir(this.directory, { recursive: true, mode: 0o700 });
          await writeFile(this.marker, `${MODEL_ID}\n`, { mode: 0o600 });
          this.progress = 100;
          this.detail = 'Kokoro is ready for iPhone answers.';
        })
        .catch(error => {
          this.error = error.message;
          this.progress = null;
          this.detail = 'Kokoro could not be downloaded. Try again.';
        })
        .finally(() => { this.installPromise = null; });
    }
    return this.status();
  }

  async load(allowDownload) {
    if (this.model) return this.model;
    if (!this.modelPromise) {
      await mkdir(this.cacheDir, { recursive: true, mode: 0o700 });
      this.modelPromise = this.loader(this.cacheDir, allowDownload, update => {
        if (typeof update?.progress === 'number') this.progress = Math.round(update.progress);
        if (update?.file) this.detail = `Downloading ${path.basename(update.file)}${this.progress == null ? '…' : `: ${this.progress}%`}`;
        else if (update?.status === 'ready') this.detail = 'Preparing Kokoro…';
      }).then(model => { this.model = model; return model; })
        .catch(error => { this.modelPromise = null; throw error; });
    }
    return this.modelPromise;
  }

  async synthesize(text, voice = DEFAULT_VOICE) {
    if (typeof text !== 'string' || !text.trim() || text.length > 8000) throw new Error('The answer is too long for Kokoro.');
    if (!kokoroVoices.has(voice)) voice = DEFAULT_VOICE;
    if (!(await this.installed()) && !this.installPromise) throw new Error('Download Kokoro in the Mac app first.');
    if (this.installPromise) await this.installPromise;
    if (!(await this.installed())) throw new Error(this.error || 'Kokoro is unavailable.');
    const model = await this.load(false);
    const rawAudio = await model.generate(text.trim(), { voice, speed: 1 });
    const audio = await this.converter(Buffer.from(rawAudio.toWav()));
    return { format: 'm4a', data: audio.toString('base64') };
  }
}
