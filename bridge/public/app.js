const $ = id => document.getElementById(id);
let pairingLink = '';
let applications = [];
function error(message) { $('error').textContent = message || ''; $('error').hidden = !message; }
async function api(url, method = 'GET', body) {
  const response = await fetch(url, { method, headers: { 'X-RayBridge': 'local',
    ...(body ? { 'Content-Type': 'application/json' } : {}) },
  ...(body ? { body: JSON.stringify(body) } : {}) });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || 'Could not connect to the Mac bridge.');
  return data;
}
async function pair() {
  if (!$('host').value) return;
  const data = await api(`/api/pair?host=${encodeURIComponent($('host').value)}`);
  pairingLink = data.link; $('qr').src = data.qr; $('qr').hidden = false;
}
async function refresh() {
  try {
    const data = await api('/api/status');
    const provider = data.provider || 'codex';
    const local = data.accountSource === 'local';
    $('provider').value = provider;
    if (provider === 'claude') {
      $('account').textContent = data.signedIn
        ? `Connected to Claude Code on this Mac${data.plan ? ` · ${data.plan}` : ''}`
        : 'Claude Code is installed but is not signed in';
      $('accountHelp').textContent = 'Uses this Mac’s normal Claude Code configuration, project instructions, tools, plugins, and MCP servers. Run claude auth login in Terminal if needed.';
      $('localAgentNote').textContent = 'Spoken requests use Claude Code’s normal project instructions and permissions. File edits are allowed; actions that require an interactive approval are denied.';
      $('workspaceLabel').textContent = 'Claude Code working folder';
    } else if (provider === 'hermes') {
      $('account').textContent = data.signedIn
        ? `Hermes is available on this Mac${data.plan ? ` · ${data.plan}` : ''}`
        : 'Hermes is not installed or configured';
      $('accountHelp').textContent = 'Uses this Mac’s normal Hermes model, memories, project instructions, tools, plugins, and computer use.';
      $('localAgentNote').textContent = 'Spoken requests use Hermes’s normal tools and permissions. Review its configuration before allowing it to control this Mac.';
      $('workspaceLabel').textContent = 'Hermes working folder';
    } else {
      $('account').textContent = data.signedIn
        ? `Connected to ${local ? "this Mac’s Codex login" : 'ChatGPT'}${data.plan ? ` · ${data.plan}` : ''}`
        : local ? 'No ChatGPT login found in this Mac’s Codex CLI' : 'Sign in to get started';
      $('accountHelp').textContent = local
        ? 'RayBridge uses the ChatGPT account and normal Codex configuration on this Mac. If needed, run codex login in Terminal.'
        : 'Uses a separate RayBridge login. The Codex access and usage limits of that ChatGPT account apply.';
      $('localAgentNote').textContent = 'Local agent mode uses this Mac’s Codex memories, tools, plugins, and computer use. Spoken requests can read and change files in the working folder and control apps you allow below.';
      $('workspaceLabel').textContent = 'Codex working folder';
    }
    $('workspaceSettings').hidden = !data.workspaceEditable;
    $('appPermissions').hidden = !data.supportsAppSelection;
    if (data.workspaceEditable && document.activeElement !== $('workspace')) $('workspace').value = data.workspace || '';
    if (data.supportsAppSelection && !applications.length) await loadApplications();
    const codex = provider === 'codex';
    $('useLocal').hidden = !codex || local; $('useSeparate').hidden = !codex || !local;
    $('login').hidden = !codex || local || data.signedIn; $('logout').hidden = !codex || local || !data.signedIn;
    if (data.signedIn || !codex) $('authLink').hidden = true;
    $('phone').textContent = data.phoneConnected ? 'iPhone connected' : 'Waiting for your iPhone';
    const before = $('host').value;
    if ([...$('host').options].map(x => x.value).join() !== data.hosts.join()) {
      $('host').replaceChildren(...data.hosts.map(host => new Option(host, host)));
      if (data.hosts.includes(before)) $('host').value = before;
      await pair();
    }
    error(data.error || '');
    if (!data.hosts.length) error('Connect this Mac to Wi-Fi to pair an iPhone.');
    await refreshKokoro();
  } catch (e) { error(e.message); }
}
async function refreshKokoro() {
  const data = await api('/api/tts/status');
  $('kokoroStatus').textContent = data.error ? `${data.detail} ${data.error}` : data.detail;
  $('kokoroProgress').hidden = !data.installing || typeof data.progress !== 'number';
  if (!$('kokoroProgress').hidden) $('kokoroProgress').value = data.progress;
  $('installKokoro').hidden = data.installed && !data.error;
  $('installKokoro').disabled = data.installing;
  $('installKokoro').textContent = data.installing ? 'Downloading Kokoro…' : data.error ? 'Retry Kokoro download' : 'Download Kokoro voice';
}
function renderApplications() {
  const query = $('appSearch').value.trim().toLocaleLowerCase();
  const visible = applications.filter(app => app.name.toLocaleLowerCase().includes(query));
  $('appList').replaceChildren(...visible.map(app => {
    const label = document.createElement('label');
    label.className = 'app-choice';
    const input = document.createElement('input');
    input.type = 'checkbox'; input.value = app.id; input.checked = app.selected;
    input.onchange = () => { app.selected = input.checked; updateAllAppsState(); };
    label.append(input, document.createTextNode(app.name));
    return label;
  }));
  if (!visible.length) $('appList').textContent = applications.length ? 'No matching apps.' : 'No compatible apps found.';
  updateAllAppsState();
}
function updateAllAppsState() {
  const selected = applications.filter(app => app.selected).length;
  $('allowAllApps').checked = applications.length > 0 && selected === applications.length;
  $('allowAllApps').indeterminate = selected > 0 && selected < applications.length;
  $('allowAllApps').disabled = !applications.length;
}
async function loadApplications() {
  const data = await api('/api/apps');
  const selected = new Set(data.selected);
  applications = data.applications.map(app => ({ ...app, selected: selected.has(app.id) }));
  $('appSearchGroup').hidden = !applications.length;
  renderApplications();
}
function action(id, run) { $(id).onclick = async () => {
  $(id).disabled = true; error('');
  try { await run(); } catch(e) { error(e.message); }
  finally { $(id).disabled = false; }
}; }
action('login', async () => {
  const { url } = await api('/api/login', 'POST');
  const parsed = new URL(url);
  if (parsed.protocol !== 'https:' || !['auth.openai.com', 'chatgpt.com', 'auth0.openai.com'].includes(parsed.hostname)) throw new Error('Unexpected sign-in address.');
  $('authLink').href = url; $('authLink').hidden = false;
  $('authLink').click();
});
action('logout', async () => { await api('/api/logout', 'POST'); await refresh(); });
$('provider').onchange = async () => {
  $('provider').disabled = true; error(''); applications = [];
  try { await api('/api/provider', 'POST', { provider: $('provider').value }); await refresh(); }
  catch (e) { error(e.message); await refresh(); }
  finally { $('provider').disabled = false; }
};
async function source(source) {
  await api('/api/account-source', 'POST', { source });
  await refresh();
}
action('useLocal', async () => source('local'));
action('useSeparate', async () => source('raybridge'));
action('saveWorkspace', async () => {
  const data = await api('/api/workspace', 'POST', { path: $('workspace').value });
  $('workspace').value = data.workspace;
  await refresh();
});
action('saveApps', async () => {
  const data = await api('/api/apps', 'POST', { apps: applications.filter(app => app.selected).map(app => app.id) });
  const selected = new Set(data.selected);
  for (const app of applications) app.selected = selected.has(app.id);
  renderApplications();
});
$('appSearch').oninput = renderApplications;
$('allowAllApps').onchange = () => {
  for (const app of applications) app.selected = $('allowAllApps').checked;
  renderApplications();
};
action('copy', async () => { await navigator.clipboard.writeText(pairingLink); $('copy').textContent = 'Pairing link copied'; });
action('revoke', async () => { await api('/api/revoke', 'POST'); await pair(); await refresh(); });
action('installKokoro', async () => { await api('/api/tts/install', 'POST'); await refreshKokoro(); });
$('host').onchange = () => pair().catch(e => error(e.message));
refresh(); setInterval(refresh, 4000);
