import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const src = readFileSync(new URL('../src/09a-attention.js', import.meta.url), 'utf8');
const a = new Function(`${src}\nreturn { attentionItems, healthScore, scoreTone };`)();

test('a clean domain has no findings and a perfect score', () => {
  const items = a.attentionItems({ kpis: { users: 10, gpos: 5 }, fleet: { online: 10, patch_compliant: 10 }, dcs: { items: [{ name: 'DC01', replication: { failures: 0 } }] }, alerts: 0 });
  assert.deepEqual(items, []);
  assert.equal(a.healthScore(items), 100);
  assert.equal(a.scoreTone(100), 'success');
});

test('findings are ordered urgent first and carry a destination and a read-only agent prompt', () => {
  const items = a.attentionItems({
    kpis: { backups_bad: 2, backups_ok: 0, backups_total: 2, gpos_needing_attention: 1, gpos: 14 },
    fleet: { online: 29, patch_compliant: 4, pending_reboot: 28, defender_off: 0, low_disk_count: 3 },
    dcs: { items: [] },
    alerts: 0,
    diskPct: 10,
  });
  const ids = items.map((i) => i.id);
  assert.deepEqual(ids.slice(0, 3).sort(), ['backups', 'disk', 'patch']);
  assert.ok(items.every((i) => i.severity === 'danger' || i.severity === 'warning'));
  assert.ok(items.findIndex((i) => i.severity === 'warning') > items.map((i) => i.severity).lastIndexOf('danger'));
  assert.ok(items.every((i) => i.go && i.go.tab && /do not change anything/.test(i.ask)));
  assert.equal(items.find((i) => i.id === 'patch').title, 'Patch compliance 14%');
});

test('score drops per finding and never goes below zero', () => {
  assert.equal(a.healthScore([{ severity: 'danger' }, { severity: 'warning' }]), 83);
  assert.equal(a.healthScore(Array(20).fill({ severity: 'danger' })), 0);
  assert.equal(a.scoreTone(70), 'warning');
  assert.equal(a.scoreTone(40), 'danger');
});

test('replication failures and unreachable DCs are urgent', () => {
  const items = a.attentionItems({ kpis: {}, fleet: null, dcs: { items: [{ name: 'DC02', reachable: false }, { name: 'DC01', replication: { failures: 3 } }] }, alerts: 2 });
  assert.deepEqual(items.map((i) => i.id), ['dc-down', 'repl', 'alerts']);
});

test('never-expiring passwords only count when they are a large share', () => {
  assert.equal(a.attentionItems({ kpis: { users: 100, users_never_expire: 5 } }).length, 0);
  assert.equal(a.attentionItems({ kpis: { users: 36, users_never_expire: 35 } })[0].id, 'never-expire');
});
