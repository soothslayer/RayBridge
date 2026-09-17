const $ = id => document.getElementById(id);
let pairingLink = '';
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
    const local = data.accountSource === 'local';
    $('account').textContent = data.signedIn
      ? `Connected to ${local ? "this Mac’s Codex login" : 'ChatGPT'}${data.plan ? ` · ${data.plan}` : ''}`
      : local ? 'No ChatGPT login found in this Mac’s Codex CLI' : 'Sign in to get started';
    $('accountHelp').textContent = local
      ? 'RayBridge uses the ChatGPT account already cached by Codex on this Mac. If needed, run codex login in Terminal.'
      : 'Uses a separate RayBridge login. The Codex access and usage limits of that ChatGPT account apply.';
    $('useLocal').hidden = local; $('useSeparate').hidden = !local;
    $('login').hidden = local || data.signedIn; $('logout').hidden = local || !data.signedIn;
    if (data.signedIn) $('authLink').hidden = true;
    $('phone').textContent = data.phoneConnected ? 'iPhone connected' : 'Waiting for your iPhone';
    const before = $('host').value;
    if ([...$('host').options].map(x => x.value).join() !== data.hosts.join()) {
      $('host').replaceChildren(...data.hosts.map(host => new Option(host, host)));
      if (data.hosts.includes(before)) $('host').value = before;
      await pair();
    }
    if (data.error) error(data.error);
    if (!data.hosts.length) error('Connect this Mac to Wi-Fi to pair an iPhone.');
  } catch (e) { error(e.message); }
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
async function source(source) {
  await api('/api/account-source', 'POST', { source });
  await refresh();
}
action('useLocal', async () => source('local'));
action('useSeparate', async () => source('raybridge'));
action('copy', async () => { await navigator.clipboard.writeText(pairingLink); $('copy').textContent = 'Pairing link copied'; });
action('revoke', async () => { await api('/api/revoke', 'POST'); await pair(); await refresh(); });
$('host').onchange = () => pair().catch(e => error(e.message));
refresh(); setInterval(refresh, 4000);
