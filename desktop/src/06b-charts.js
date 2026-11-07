// ============================================================================
// §6b CHARTS (accessible SVG components; geometry lives in §6a)
// ============================================================================
function chartAriaLabel(title, data) {
  const parts = (data || []).map((d) => `${d.label} ${d.display != null ? d.display : d.value}`);
  return title ? `${title}: ${parts.join(', ')}` : parts.join(', ');
}

// Keyboard-accessible click props for HTML (non-SVG) rows: Enter activates on keydown, Space on keyup.
function chartActivate(onClick) {
  if (!onClick) return {};
  return {
    role: 'button',
    tabIndex: 0,
    onClick,
    onKeyDown: (e) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        onClick(e);
      } else if (e.key === ' ') {
        e.preventDefault();
      }
    },
    onKeyUp: (e) => {
      if (e.key === ' ') {
        e.preventDefault();
        onClick(e);
      }
    },
  };
}

// SVG shapes are decorative (aria-hidden); mouse click only. The keyboard path is the HTML legend or label row.
function chartMouse(onClick) {
  return onClick ? { onClick, className: 'hs-clickable' } : {};
}

function toneColor(tone) {
  if (tone === 'danger') return 'var(--ui-red, var(--ui-accent))';
  if (tone === 'warning') return 'var(--ui-yellow, var(--ui-accent))';
  if (tone === 'success') return 'var(--ui-green, var(--ui-accent))';
  return seriesColor(0);
}

// A figure with role=img hides its children from assistive tech, so interactive charts are a labelled group.
function ChartFigure({ title, data, className, children }) {
  const interactive = (data || []).some((d) => d.onClick);
  return jsx('figure', {
    className: `hs-chart${className ? ` ${className}` : ''}`,
    role: interactive ? 'group' : 'img',
    'aria-label': chartAriaLabel(title, data),
    children,
  });
}

function ChartLegend({ data, total, showPct }) {
  return jsx('ul', {
    className: 'hs-chart-legend',
    children: data.map((d, i) => {
      const pct = total > 0 ? Math.round((d.value / total) * 100) : 0;
      const inner = [
        jsx('span', { className: 'hs-chart-swatch', style: { background: seriesColor(i) } }),
        jsx('span', { className: 'hs-chart-legend-label', children: d.label }),
        jsx('span', { className: 'hs-chart-legend-value', children: showPct ? `${d.value} (${pct}%)` : String(d.value) }),
      ];
      return jsx(
        'li',
        {
          children: d.onClick
            ? jsx('button', { type: 'button', className: 'hs-chart-legend-row hs-chart-btn', onClick: d.onClick, children: inner })
            : jsx('div', { className: 'hs-chart-legend-row', children: inner }),
        },
        `${i}-${d.label}`,
      );
    }),
  });
}

function Donut({ data, size = 140, center, title }) {
  const r = size / 2 - 2;
  const inner = r * 0.62;
  const total = data.reduce((s, d) => s + (d.value > 0 ? d.value : 0), 0);
  const arcs = donutArcs(data.map((d) => d.value), r, inner);
  return jsxs(ChartFigure, {
    title,
    data,
    className: 'hs-chart-donut',
    children: [
      jsxs('svg', {
        width: size,
        height: size,
        viewBox: `${-size / 2} ${-size / 2} ${size} ${size}`,
        'aria-hidden': 'true',
        focusable: 'false',
        children: [
          total <= 0 ? jsx('circle', { r: (r + inner) / 2, fill: 'none', stroke: 'var(--ui-stroke-tertiary)', strokeWidth: r - inner }) : null,
          ...arcs.map((a, k) => {
            const d = data[a.index];
            return jsx(
              'path',
              {
                d: a.d,
                fill: seriesColor(a.index),
                ...chartMouse(d.onClick),
              },
              k,
            );
          }),
          center ? jsx('text', { x: 0, y: 0, textAnchor: 'middle', dominantBaseline: 'central', className: 'hs-chart-center', children: center }) : null,
        ],
      }),
      jsx(ChartLegend, { data, total, showPct: true }),
    ],
  });
}

function BarList({ data, max = null, unit, title }) {
  const widths = barWidths(data.map((d) => d.value), max, 100);
  return jsx(ChartFigure, {
    title,
    data,
    className: 'hs-chart-bars',
    children: data.map((d, i) =>
      jsxs(
        'div',
        {
          className: `hs-chart-barrow${d.onClick ? ' hs-clickable' : ''}`,
          ...chartActivate(d.onClick),
          children: [
            jsx('span', { className: 'hs-chart-barlabel', title: d.label, children: d.label }),
            jsx('span', {
              className: 'hs-chart-bartrack',
              children: jsx('i', {
                style: { width: `${widths[i]}%`, background: toneColor(d.tone) },
              }),
            }),
            jsx('span', { className: 'hs-chart-barvalue', children: d.display != null ? d.display : `${d.value}${unit ? ` ${unit}` : ''}` }),
          ],
        },
        `${i}-${d.label}`,
      ),
    ),
  });
}

function Histogram({ data, height = 120, title }) {
  const top = Math.max(0, ...data.map((d) => d.value));
  const barH = height - 8;
  const slot = 100 / Math.max(1, data.length);
  return jsxs(ChartFigure, {
    title,
    data,
    className: 'hs-chart-hist',
    children: [
      jsx('svg', {
        width: '100%',
        height,
        viewBox: `0 0 100 ${height}`,
        preserveAspectRatio: 'none',
        'aria-hidden': 'true',
        focusable: 'false',
        children: data.map((d, i) => {
          const h = barWidths([d.value], top, barH)[0];
          return jsx(
            'rect',
            { x: i * slot + slot * 0.15, y: 4 + barH - h, width: slot * 0.7, height: h, fill: seriesColor(0), ...chartMouse(d.onClick) },
            `${i}-${d.label}`,
          );
        }),
      }),
      jsx('div', {
        className: 'hs-chart-histlabels',
        children: data.map((d, i) => {
          const inner = [
            jsx('span', { className: 'hs-chart-histcount', children: String(d.value) }),
            jsx('span', { className: 'hs-chart-histlabel', children: d.label }),
          ];
          return d.onClick
            ? jsx('button', { type: 'button', className: 'hs-chart-histcol hs-chart-btn', onClick: d.onClick, children: inner }, `${i}-${d.label}`)
            : jsx('div', { className: 'hs-chart-histcol', children: inner }, `${i}-${d.label}`);
        }),
      }),
    ],
  });
}

function StackedBar({ data, title }) {
  const total = data.reduce((s, d) => s + (d.value > 0 ? d.value : 0), 0);
  let x = 0;
  const segs = [];
  data.forEach((d, i) => {
    if (!(d.value > 0) || total <= 0) return;
    const w = (d.value / total) * 100;
    segs.push(
      jsx(
        'rect',
        {
          x,
          y: 0,
          width: w,
          height: 14,
          fill: seriesColor(i),
          ...chartMouse(d.onClick),
        },
        `${i}-${d.label}`,
      ),
    );
    x += w;
  });
  return jsxs(ChartFigure, {
    title,
    data,
    className: 'hs-chart-stacked',
    children: [
      jsx('svg', {
        width: '100%',
        height: 14,
        viewBox: '0 0 100 14',
        preserveAspectRatio: 'none',
        'aria-hidden': 'true',
        focusable: 'false',
        children: [jsx('rect', { x: 0, y: 0, width: 100, height: 14, fill: 'var(--ui-stroke-tertiary)' }, 'bg'), ...segs],
      }),
      jsx(ChartLegend, { data, total, showPct: false }),
    ],
  });
}

function Sparkline({ points, width = 160, height = 36, label, valueText }) {
  const d = sparkPath(points || [], width, height - 4);
  const text = valueText != null ? String(valueText) : '';
  const aria = [label, text].filter(Boolean).join(': ') || 'Trend';
  return jsxs('figure', {
    className: 'hs-chart hs-chart-spark',
    role: 'img',
    'aria-label': aria,
    children: [
      jsx('svg', {
        width,
        height,
        viewBox: `0 0 ${width} ${height}`,
        'aria-hidden': 'true',
        focusable: 'false',
        children: d
          ? jsx('path', { d, transform: 'translate(0 2)', fill: 'none', stroke: seriesColor(0), strokeWidth: 1.5, strokeLinejoin: 'round', strokeLinecap: 'round' })
          : jsx('line', { x1: 0, x2: width, y1: height / 2, y2: height / 2, stroke: 'var(--ui-stroke-tertiary)', strokeDasharray: '2 3' }),
      }),
      text ? jsx('span', { className: 'hs-chart-sparkvalue', children: text }) : null,
    ],
  });
}

function StatTile({ label, value, sub, tone, onClick }) {
  return jsx('div', { className: 'hs-stat', children: jsx(Kpi, { label, value, sub, tone, onClick }) });
}
