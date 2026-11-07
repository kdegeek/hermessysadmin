// ============================================================================
// §6a CHART GEOMETRY (pure functions: no imports, no JSX; unit-tested under node)
// ============================================================================
function chartNum(n) {
  return n.toFixed(2);
}

function donutPoint(radius, angle) {
  return [radius * Math.sin(angle), -radius * Math.cos(angle)];
}

function donutSlicePath(r, inner, start, end) {
  const large = end - start > Math.PI ? 1 : 0;
  const o1 = donutPoint(r, start);
  const o2 = donutPoint(r, end);
  const i1 = donutPoint(inner, start);
  const i2 = donutPoint(inner, end);
  return [
    `M${chartNum(o1[0])},${chartNum(o1[1])}`,
    `A${chartNum(r)},${chartNum(r)} 0 ${large} 1 ${chartNum(o2[0])},${chartNum(o2[1])}`,
    `L${chartNum(i2[0])},${chartNum(i2[1])}`,
    `A${chartNum(inner)},${chartNum(inner)} 0 ${large} 0 ${chartNum(i1[0])},${chartNum(i1[1])}`,
    'Z',
  ].join(' ');
}

// Arcs start at 12 o'clock and run clockwise. `index` is the position in the input values.
function donutArcs(values, r, inner) {
  const clean = values.map((v) => (Number.isFinite(v) && v > 0 ? v : 0));
  const total = clean.reduce((s, v) => s + v, 0);
  if (total <= 0) return [];
  const arcs = [];
  let angle = 0;
  clean.forEach((value, index) => {
    if (value <= 0) return;
    const sweep = (value / total) * Math.PI * 2;
    const pct = (value / total) * 100;
    if (value === total) {
      // A single slice is a full ring; one SVG arc cannot draw 360 degrees, so use two halves.
      arcs.push({ d: donutSlicePath(r, inner, 0, Math.PI), start: 0, end: Math.PI, value, pct: pct / 2, index });
      arcs.push({ d: donutSlicePath(r, inner, Math.PI, Math.PI * 2), start: Math.PI, end: Math.PI * 2, value, pct: pct / 2, index });
    } else {
      arcs.push({ d: donutSlicePath(r, inner, angle, angle + sweep), start: angle, end: angle + sweep, value, pct, index });
    }
    angle += sweep;
  });
  return arcs;
}

function barWidths(values, max, width) {
  const finite = values.map((v) => (Number.isFinite(v) ? v : 0));
  const top = max != null && max > 0 ? max : Math.max(0, ...finite);
  return finite.map((v) => {
    if (v <= 0 || top <= 0) return 0;
    const w = (v / top) * width;
    return Math.min(width, Math.max(2, w));
  });
}

function histogramBins(values, edges) {
  const counts = edges.map(() => 0);
  values.forEach((v) => {
    if (v == null || !Number.isFinite(v)) return;
    for (let i = edges.length - 1; i >= 0; i -= 1) {
      if (v >= edges[i]) {
        counts[i] += 1;
        return;
      }
    }
  });
  return counts;
}

// Format: "M0.00,20.00 L50.00,10.00 L100.00,0.00" (y grows downward; a flat series sits at mid-height).
function sparkPath(points, width, height) {
  const pts = points.filter((p) => Number.isFinite(p));
  if (pts.length < 2) return '';
  const lo = Math.min(...pts);
  const hi = Math.max(...pts);
  const span = hi - lo;
  return pts
    .map((p, i) => {
      const x = (i / (pts.length - 1)) * width;
      const y = span === 0 ? height / 2 : height - ((p - lo) / span) * height;
      return `${i === 0 ? 'M' : 'L'}${chartNum(x)},${chartNum(y)}`;
    })
    .join(' ');
}

function seriesColor(i) {
  return `var(--hs-series-${((i % 6) + 6) % 6})`;
}
