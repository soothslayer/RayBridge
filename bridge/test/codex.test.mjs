import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { CodexClient, codexLaunch, localCodexCandidates, localServerResponse, validateAllowedApps } from '../codex.mjs';

test('isolated account uses RayBridge CODEX_HOME and file credentials', () => {
  const launch = codexLaunch('/private/raybridge/codex', 'raybridge', {
    PATH: '/bin', HOME: '/Users/test', TMPDIR: '/private/tmp', CODEX_HOME: '/custom/codex'
  });
  assert.equal(launch.env.CODEX_HOME, '/private/raybridge/codex');
  assert.ok(launch.args.includes('cli_auth_credentials_store="file"'));
  assert.ok(launch.args.includes('features.shell_tool=false'));
  assert.ok(launch.args.includes('permissions.raybridge.network.enabled=false'));
});

test('local account inherits the machine Codex configuration and capabilities', () => {
  const defaultHome = codexLaunch('/private/raybridge/codex', 'local', {
    PATH: '/bin', HOME: '/Users/test', TMPDIR: '/private/tmp', RAYBRIDGE_TEST_VALUE: 'inherited'
  });
  assert.equal(defaultHome.env.CODEX_HOME, undefined);
  assert.equal(defaultHome.env.RAYBRIDGE_TEST_VALUE, 'inherited');
  assert.deepEqual(defaultHome.args, ['app-server', '--listen', 'stdio://']);

  const customHome = codexLaunch('/private/raybridge/codex', 'local', {
    PATH: '/bin', HOME: '/Users/test', CODEX_HOME: '/custom/codex'
  });
  assert.equal(customHome.env.CODEX_HOME, '/custom/codex');
});

test('local turns use the selected workspace and allow chosen Computer Use apps', async t => {
  const computerUseHome = await mkdtemp('/tmp/raybridge-codex-home-');
  t.after(() => rm(computerUseHome, { recursive: true, force: true }));
  const codex = new CodexClient('/private/raybridge/codex', 'codex', 'local', '/Users/test', ['com.apple.calculator']);
  codex.localCodexHome = computerUseHome;
  codex.workspace = '/Users/test';
  const calls = [];
  codex.call = async (method, params) => {
    calls.push([method, params]);
    return method === 'thread/start' ? { thread: { id: 'thread-1' } } : { turn: { id: 'turn-1' } };
  };
  assert.equal(await codex.newThread(), 'thread-1');
  await codex.ask('thread-1', 'Read my notes', null);
  assert.equal(calls[0][1].cwd, '/Users/test');
  assert.equal(calls[0][1].sandbox, 'danger-full-access');
  assert.equal(calls[0][1].approvalPolicy, 'never');
  assert.equal(calls[0][1].approvalsReviewer, undefined);
  assert.match(calls[0][1].developerInstructions, /memories, local files, tools, plugins, and computer use/);
  assert.equal(await readFile(`${computerUseHome}/computer-use/sessions/thread-1.toml`, 'utf8'),
    '[apps]\nallowed = ["com.apple.calculator"]\n');
  assert.deepEqual(calls[1][1].sandboxPolicy, { type: 'dangerFullAccess' });
  assert.equal(calls[1][1].approvalPolicy, 'never');
  // An automatic reviewer could decline, which the user could neither see nor override.
  assert.equal(calls[1][1].approvalsReviewer, undefined);
});

test('Computer Use app identifiers are validated and deduplicated', () => {
  assert.deepEqual(validateAllowedApps(['com.apple.calculator', 'com.apple.calculator']), ['com.apple.calculator']);
  assert.throws(() => validateAllowedApps(['../Terminal']), /installed app list/);
  assert.throws(() => validateAllowedApps('com.apple.calculator'), /installed app list/);
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

test('local turns answer approval requests instead of stopping for a person', () => {
  // Nothing should ask under danger-full-access, but a request that slips
  // through must not leave a blind user waiting on a prompt they cannot see.
  assert.deepEqual(localServerResponse('item/commandExecution/requestApproval'), { decision: 'acceptForSession' });
  assert.deepEqual(localServerResponse('item/fileChange/requestApproval'), { decision: 'acceptForSession' });
  const grant = localServerResponse('item/permissions/requestApproval', { permissions: {
    network: { enabled: true }, fileSystem: { write: ['/Users/test'] }
  } });
  assert.deepEqual(grant, { permissions: {
    network: { enabled: true },
    fileSystem: { read: null, write: ['/Users/test'] }
  }, scope: 'session' });
  // An elicitation wants typed data, not permission; declining keeps the turn moving.
  assert.deepEqual(localServerResponse('mcpServer/elicitation/request'), {
    action: 'decline', content: null, _meta: null
  });
  // A request needing a typed answer has no entry, so it still fails closed.
  assert.equal(localServerResponse('item/tool/requestUserInput'), undefined);
});

test('the vision-only RayBridge account keeps its restrictions', () => {
  const launch = codexLaunch('/private/raybridge/codex', 'raybridge', { PATH: '/bin', HOME: '/Users/test' });
  assert.ok(launch.args.includes('permissions.raybridge.network.enabled=false'));
  assert.ok(launch.args.includes('features.shell_tool=false'));
  assert.ok(launch.args.includes('mcp_servers={}'));
});
