import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
const root = new URL('../../', import.meta.url);
test('remote naming is admin-only and requires an active device MAC', async () => {
  const source = await readFile(new URL('supabase/functions/admin-users/index.ts', root), 'utf8');
  assert.ok(source.indexOf('profile.role!=="admin"') < source.indexOf('body.action==="save_device_name"'));
  assert.match(source, /device.active_mac!==mac/);
  assert.match(source, /mac_already_bound/);
  assert.match(source, /hostname_in_use/);
  const migration = await readFile(new URL('supabase/migrations/20260915151759_managed_computer_names.sql', root), 'utf8');
  assert.match(migration, /enable row level security/);
  assert.match(migration, /revoke all.*anon, authenticated/);
});
test('name rows render available actions without exposing an unescaped hostname', async () => {
  const app = await readFile(new URL('dashboard/github-pages/app.js', root), 'utf8');
  const code = app.slice(app.indexOf('function renderMachineNames()'), app.indexOf('async function downloadRelease()'));
  const output = { innerHTML: '' };
  const escaped = (value) => String(value ?? '').replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('"','&quot;');
  const context = { state: { devices: [{ id:'test',hostname:'<img>',os_type:'Windows',active_mac:'AA:BB:CC:DD:EE:FF',active_adapter_name:'Ethernet' }],nameBindings:[] }, $:()=>output, esc:escaped, platformFromOs:()=> 'windows', document:{querySelectorAll:()=>[]}, emptyRow:()=>'' };
  vm.runInNewContext(code + ';renderMachineNames();', context);
  assert.match(output.innerHTML, /AA:BB:CC:DD:EE:FF/);
  assert.match(output.innerHTML, /Vincular \/ aplicar/);
  assert.doesNotMatch(output.innerHTML, /<img>/);
  context.state.devices[0].active_mac = null;
  vm.runInNewContext('renderMachineNames();', context);
  assert.match(output.innerHTML, /name-save[^>]+disabled/);
});
test('panel warns of reboot and displays current hostname and active physical MAC', async () => {
  const app = await readFile(new URL('dashboard/github-pages/app.js', root), 'utf8');
  const html = await readFile(new URL('dashboard/github-pages/index.html', root), 'utf8');
  assert.match(app, /confirm\(`Vincular/);
  assert.match(app, /save_device_name/);
  assert.match(html, /reinicialização em 60 segundos/);
  assert.match(html, /Nome atual/);
  assert.match(html, /MAC físico/);
});
test('custom device authentication is used instead of the user-JWT gateway', async () => {
  const cfg = await readFile(new URL('supabase/config.toml', root), 'utf8');
  const sync = await readFile(new URL('supabase/functions/device-sync/index.ts', root), 'utf8');
  assert.match(cfg, /verify_jwt = false/);
  assert.match(sync, /device_secret_hash !== await sha256\(bearer\)/);
  assert.match(sync, /\.eq\("device_id", deviceId\)\.eq\("enabled", true\)/);
  assert.match(sync, /intersects\(\[binding.mac\], incomingMacs\)/);
});
