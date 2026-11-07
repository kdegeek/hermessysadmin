import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = (f) => readFileSync(new URL(`../src/${f}`, import.meta.url), 'utf8');
const c = new Function(`${read('04-formatters.js')}\n${read('12b-tab-catalog.js')}\nreturn { catalogBuildParams, catalogColumns, catalogSummaryText, catalogAsList };`)();

const entry = (params) => ({ params });

test('integer min/max and whole-number checks', () => {
  const e = entry([{ name: 'N', type: 'integer', minimum: 1, maximum: 5 }]);
  assert.deepEqual(c.catalogBuildParams(e, { N: '3' }), { args: { N: 3 } });
  assert.match(c.catalogBuildParams(e, { N: '0' }).error, /at least 1/);
  assert.match(c.catalogBuildParams(e, { N: '6' }).error, /at most 5/);
  assert.match(c.catalogBuildParams(e, { N: '1.5' }).error, /whole number/);
});

test('required is enforced, optional empty is omitted', () => {
  const e = entry([{ name: 'A', type: 'string', required: true }, { name: 'B', type: 'string' }]);
  assert.match(c.catalogBuildParams(e, { A: ' ', B: '' }).error, /A is required/);
  assert.deepEqual(c.catalogBuildParams(e, { A: 'x', B: '' }), { args: { A: 'x' } });
});

test('arrays split and target params are skipped', () => {
  const e = entry([{ name: 'L', type: 'array' }, { name: 'computers', type: 'array', required: true }]);
  assert.deepEqual(c.catalogBuildParams(e, { L: 'a, b;c' }), { args: { L: ['a', 'b', 'c'] } });
});

test('boolean is sent with a declared default, otherwise only when true', () => {
  const withDef = entry([{ name: 'F', type: 'boolean', default: true }]);
  assert.deepEqual(c.catalogBuildParams(withDef, { F: false }), { args: { F: false } });
  const noDef = entry([{ name: 'F', type: 'boolean' }]);
  assert.deepEqual(c.catalogBuildParams(noDef, { F: false }), { args: {} });
  assert.deepEqual(c.catalogBuildParams(noDef, { F: true }), { args: { F: true } });
});

test('columns: declared order with host first, fallback to key union', () => {
  const rows = [{ a: 1, host: 'h' }, { b: 2 }];
  assert.deepEqual(c.catalogColumns(rows, { columns: ['a', 'b'] }), ['host', 'a', 'b']);
  assert.deepEqual(c.catalogColumns(rows, { columns: [] }), ['host', 'a', 'b']);
  assert.deepEqual(c.catalogColumns([{ x: 1 }], {}), ['x']);
});

test('summary text and list normalisation', () => {
  assert.equal(c.catalogSummaryText({ hosts: 12, ok: 11, failed: 1 }), '12 hosts · 11 ok · 1 failed');
  assert.equal(c.catalogSummaryText(null), '');
  assert.deepEqual(c.catalogAsList({ host: 'h' }), [{ host: 'h' }]);
  assert.deepEqual(c.catalogAsList(null), []);
});
