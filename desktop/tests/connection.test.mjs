import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = (f) => readFileSync(new URL(`../src/${f}`, import.meta.url), 'utf8');
const c = new Function(`${read('04-formatters.js')}\nreturn { connectionLabel, identityLine };`)();

test('connection label per transport and run-as', () => {
  assert.equal(c.connectionLabel({ transport: 'winrm', host: 'dc01' }), 'via dc01 (WinRM)');
  assert.equal(c.connectionLabel({}), 'via jump host (WinRM)');
  assert.equal(c.connectionLabel({ transport: 'local', run_as: 'hermes_user' }), 'local PowerShell as the Hermes user');
  assert.match(c.connectionLabel({ transport: 'local', run_as: 'account', run_as_user: 'CORP\\svc' }), /as CORP\\svc \(network logons\)/);
});

test('identity line shows both identities, or the network error', () => {
  const ok = c.identityLine({ transport: 'local', run_as: 'account', local_identity: 'CORP\\hermes', network_identity: 'CORP\\svc', dc: 'dc01.corp' });
  assert.equal(ok, 'Transport local PowerShell (run as account) · local identity CORP\\hermes · network identity CORP\\svc at dc01.corp');
  const bad = c.identityLine({ transport: 'local', run_as: 'account', identity: 'CORP\\hermes', network_identity_error: 'Access is denied' });
  assert.match(bad, /network identity unknown \(Access is denied\)/);
  assert.match(c.identityLine({ transport: 'winrm', identity: 'CORP\\svc', network_identity: 'CORP\\svc' }), /^Transport WinRM · local identity CORP\\svc/);
});
