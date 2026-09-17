import test from 'node:test';
import assert from 'node:assert/strict';
import { codexLaunch, localCodexCandidates } from '../codex.mjs';

test('isolated account uses RayBridge CODEX_HOME and file credentials', () => {
  const launch = codexLaunch('/private/raybridge/codex', 'raybridge', {
    PATH: '/bin', HOME: '/Users/test', TMPDIR: '/private/tmp', CODEX_HOME: '/custom/codex'
  });
  assert.equal(launch.env.CODEX_HOME, '/private/raybridge/codex');
  assert.ok(launch.args.includes('cli_auth_credentials_store="file"'));
  assert.ok(launch.args.includes('features.shell_tool=false'));
  assert.ok(launch.args.includes('permissions.raybridge.network.enabled=false'));
});

test('local account reuses the machine Codex home without weakening restrictions', () => {
  const defaultHome = codexLaunch('/private/raybridge/codex', 'local', {
    PATH: '/bin', HOME: '/Users/test', TMPDIR: '/private/tmp'
  });
  assert.equal(defaultHome.env.CODEX_HOME, undefined);
  assert.ok(!defaultHome.args.includes('cli_auth_credentials_store="file"'));
  assert.ok(defaultHome.args.includes('features.plugins=false'));
  assert.ok(defaultHome.args.includes('mcp_servers={}'));
  assert.ok(defaultHome.args.includes('model_provider="openai"'));
  assert.ok(defaultHome.args.includes('default_permissions="raybridge"'));

  const customHome = codexLaunch('/private/raybridge/codex', 'local', {
    PATH: '/bin', HOME: '/Users/test', CODEX_HOME: '/custom/codex'
  });
  assert.equal(customHome.env.CODEX_HOME, '/custom/codex');
});

test('unknown account source is rejected', () => {
  assert.throws(() => codexLaunch('/tmp/codex', 'other', {}), /Unknown Codex account source/);
});

test('local runtime candidates include installed apps, CLI paths, and bundled fallback', () => {
  const candidates = localCodexCandidates('/bundle/codex', { HOME: '/Users/test' });
  assert.ok(candidates.includes('/Applications/ChatGPT.app/Contents/Resources/codex'));
  assert.ok(candidates.includes('/Users/test/.local/bin/codex'));
  assert.equal(candidates.at(-1), '/bundle/codex');
  assert.equal(new Set(candidates).size, candidates.length);
  assert.deepEqual(localCodexCandidates('/bundle/codex', {
    HOME: '/Users/test', RAYBRIDGE_LOCAL_CODEX: '/chosen/codex'
  }), ['/chosen/codex']);
});
