const $ = id => document.getElementById(id);
let pairingLink = '';
function error(message) { $('error').textContent = message || ''; $('error').hidden = !message; }
async function api(url, method = 'GET') {
  const response = await fetch(url, { method, headers: { 'X-RayBridge': 'local' } });
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
    $('account').textContent = data.signedIn ? `Connected to ChatGPT${data.plan ? ` · ${data.plan}` : ''}` : 'Sign in to get started';
    $('login').hidden = data.signedIn; $('logout').hidden = !data.signedIn;
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
action('copy', async () => { await navigator.clipboard.writeText(pairingLink); $('copy').textContent = 'Pairing link copied'; });
action('revoke', async () => { await api('/api/revoke', 'POST'); await pair(); await refresh(); });
$('host').onchange = () => pair().catch(e => error(e.message));
refresh(); setInterval(refresh, 4000);
