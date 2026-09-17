import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { KokoroService } from '../tts.mjs';

test('Kokoro is opt-in, installs once, and returns compressed audio', async t => {
  const dataDir = await mkdtemp('/tmp/raybridge-tts-test-');
  t.after(() => rm(dataDir, { recursive: true, force: true }));
  const loads = [], conversions = [];
  const service = new KokoroService(dataDir, {
    loader: async (cacheDir, allowDownload, progress) => {
      loads.push({ cacheDir, allowDownload });
      progress({ file: 'model_q4.onnx', progress: 50 });
      return { generate: async (text, options) => ({
        toWav: () => { assert.equal(text, 'Hello'); assert.equal(options.voice, 'af_bella'); return Uint8Array.from([1, 2, 3]).buffer; }
      }) };
    },
    converter: async wav => { conversions.push(wav); return Buffer.from('compressed'); }
  });
  assert.equal((await service.status()).installed, false);
  await assert.rejects(service.synthesize('Hello'), /Download Kokoro/);
  await service.startInstall();
  while (!(await service.status()).installed) await new Promise(resolve => setImmediate(resolve));
  const audio = await service.synthesize('Hello', 'af_bella');
  assert.deepEqual(audio, { format: 'm4a', data: Buffer.from('compressed').toString('base64') });
  assert.equal(loads.length, 1);
  assert.equal(loads[0].allowDownload, true);
  assert.equal(conversions.length, 1);
});

test('Kokoro rejects unbounded text before model work', async t => {
  const dataDir = await mkdtemp('/tmp/raybridge-tts-bounds-');
  t.after(() => rm(dataDir, { recursive: true, force: true }));
  const service = new KokoroService(dataDir, { loader: async () => { throw new Error('should not load'); } });
  await assert.rejects(service.synthesize('a'.repeat(8001)), /too long/);
});
