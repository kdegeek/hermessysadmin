import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const src = readFileSync(new URL('../src/06a-chart-geometry.js', import.meta.url), 'utf8');
const g = new Function(`${src}\nreturn { donutArcs, barWidths, histogramBins, sparkPath, seriesColor };`)();

test('donut skips zeros and sums to 100%', () => {
  const arcs = g.donutArcs([1, 0, 3], 50, 30);
  assert.equal(arcs.length, 2);
  assert.equal(Math.round(arcs.reduce((s, a) => s + a.pct, 0)), 100);
});

test('donut single value draws a full ring', () => {
  const arcs = g.donutArcs([5], 50, 30);
  assert.equal(arcs.length, 2);
  assert.ok(arcs.every((a) => a.d.startsWith('M')));
  assert.equal(Math.round(arcs.reduce((s, a) => s + a.pct, 0)), 100);
});

test('donut with no positive values has no arcs', () => {
  assert.deepEqual(g.donutArcs([0, 0], 50, 30), []);
});

test('bar widths scale and keep tiny values visible', () => {
  assert.deepEqual(g.barWidths([10, 5, 0, 0.01], null, 100), [100, 50, 0, 2]);
});

test('histogram bins with open last bin', () => {
  assert.deepEqual(g.histogramBins([0, 3, 7, 40, 200, null], [0, 7, 35, 90]), [2, 1, 1, 1]);
});

test('sparkline', () => {
  assert.equal(g.sparkPath([1], 100, 20), '');
  assert.equal(g.sparkPath([1, 2, 3], 100, 20), 'M0.00,20.00 L50.00,10.00 L100.00,0.00');
  assert.equal(g.sparkPath([4, 4], 100, 20), 'M0.00,10.00 L100.00,10.00');
  assert.equal(g.seriesColor(7), 'var(--hs-series-1)');
});
