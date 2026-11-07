// ============================================================================
// §6 UI PRIMITIVES
// ============================================================================
// A Codicon glyph (the font the host already ships for its own UI and our sidebar entry).
function Ico(name, key) {
  return jsx('i', { className: `codicon codicon-${name} hs-ico`, 'aria-hidden': 'true' }, key);
}

function Badge({ tone, title, children }) {
  return jsx('span', { className: `hs-badge${tone ? ` ${tone}` : ''}`, title, children });
}

function TierTag({ tier }) {
  return jsx('span', { className: `hs-tier hs-tier-${tier}`, children: tier === 'P' ? 'PROTECTED' : tier });
}

function Dot({ tone }) {
  return jsx(StatusDot, { tone: tone || 'muted' });
}

function Callout({ tone, icon, children }) {
  return jsxs('div', {
    className: `hs-callout ${tone || 'accent'}`,
    children: [icon ? jsx('span', { children: icon }) : null, jsx('div', { children })],
  });
}

function ErrorBox({ error }) {
  const e = error || {};
  return jsx(Callout, {
    tone: 'red',
    icon: Ico('warning'),
    children: jsxs('div', {
      children: [
        jsxs('div', { children: [jsx('b', { children: e.type || 'Error' }), `: ${e.message || 'Something went wrong.'}`] }),
        e.hint ? jsx('div', { className: 'hs-muted hs-small', children: e.hint }) : null,
      ],
    }),
  });
}

function Spinner({ label }) {
  return jsxs('div', { className: 'hs-loading', children: [jsx(GlyphSpinner, {}), jsx('span', { children: label || 'Reading from the domain…' })] });
}

// Renders children(data) once the query envelope is ok; spinner or error otherwise.
function Pending({ q, label, children }) {
  if (!q.res) return jsx(Spinner, { label });
  if (!q.res.ok) return jsx(ErrorBox, { error: q.res.error });
  return children(q.res.data || {});
}

function Btn({ kind, small, className, ...rest }) {
  const variant = kind === 'primary' ? 'default' : kind === 'solid-danger' ? 'destructive' : kind === 'ghost' ? 'ghost' : 'outline';
  const cls = [kind === 'danger' ? 'hs-danger' : '', className || ''].filter(Boolean).join(' ');
  return jsx(Button, { type: 'button', variant, size: small ? 'xs' : 'sm', className: cls || undefined, ...rest });
}

function Chip({ on, onClick, children }) {
  return jsx('button', { type: 'button', className: `hs-chip${on ? ' on' : ''}`, onClick, children });
}

function Seg({ value, options, onChange }) {
  return jsx('div', {
    className: 'hs-seg',
    children: options.map(([v, label]) =>
      jsx('button', { type: 'button', className: v === value ? 'on' : '', onClick: () => onChange(v), children: label }, v),
    ),
  });
}

function Field({ label, children }) {
  return jsxs('label', { className: 'hs-field', children: [jsx('span', { children: label }), children] });
}

function TextInput({ value, onChange, placeholder, mono, type, autoFocus, onEnter, list: listId }) {
  return jsx('input', {
    className: `hs-input${mono ? ' hs-mono' : ''}`,
    type: type || 'text',
    value: value === null || value === undefined ? '' : value,
    placeholder,
    autoFocus,
    list: listId,
    spellCheck: false,
    autoComplete: 'off',
    onChange: (e) => onChange(e.target.value),
    onKeyDown: onEnter ? (e) => { if (e.key === 'Enter') onEnter(); } : undefined,
  });
}

function TextArea({ value, onChange, placeholder, mono }) {
  return jsx('textarea', {
    className: `hs-input${mono ? ' hs-mono' : ''}`,
    value: value || '',
    placeholder,
    spellCheck: false,
    onChange: (e) => onChange(e.target.value),
  });
}

function CheckRow({ checked, onChange, label }) {
  return jsxs('label', {
    className: 'hs-check',
    children: [jsx('input', { type: 'checkbox', checked: !!checked, onChange: (e) => onChange(e.target.checked) }), jsx('span', { children: label })],
  });
}

function Toggle({ on, onChange, disabled, title }) {
  return jsx(Switch, { size: 'xs', checked: !!on, disabled, title, onCheckedChange: onChange });
}

function KV({ rows, keyWidth }) {
  return jsx('div', {
    className: 'hs-kv',
    style: keyWidth ? { gridTemplateColumns: `${keyWidth}px 1fr` } : undefined,
    children: rows.filter(Boolean).map(([k, v]) =>
      jsxs('div', { className: 'hs-kv-row', children: [jsx('span', { className: 'hs-k', children: k }), jsx('span', { children: v })] }, k),
    ),
  });
}

function Card({ title, sub, right, className, children }) {
  return jsxs('div', {
    className: `hs-card${className ? ` ${className}` : ''}`,
    children: [
      title
        ? jsxs('h3', { children: [title, sub ? jsx('span', { className: 'hs-sub', children: sub }) : null, jsx('span', { className: 'hs-grow' }), right || null] })
        : null,
      children,
    ],
  });
}

function Kpi({ value, label, sub, tone, onClick }) {
  return jsxs('button', {
    type: 'button',
    className: 'hs-kpi',
    onClick,
    children: [
      jsx('div', { className: 'hs-v', children: value }),
      jsx('div', { className: 'hs-l', children: label }),
      jsx('div', { className: `hs-s ${tone ? `hs-text-${tone}` : 'hs-muted'}`, children: sub || ' ' }),
    ],
  });
}

function Table({ head, children }) {
  return jsxs('table', {
    className: 'hs-table',
    children: [
      head ? jsx('thead', { children: jsx('tr', { children: head.map((h, i) => jsx('th', { children: h }, i)) }) }) : null,
      jsx('tbody', { children }),
    ],
  });
}

function EmptyRow({ cols, text }) {
  return jsx('tr', { children: jsx('td', { colSpan: cols, className: 'hs-empty-row', children: text }) });
}

function AuditDecision({ row }) {
  const failed = String(row.result || '').startsWith('failed');
  return jsx(Badge, { tone: decisionTone(row), title: row.result, children: `${row.decision}${failed ? ` · ${row.result}` : ''}` });
}

function SearchBox({ value, onChange, placeholder, focusSignal }) {
  const ref = useRef(null);
  useEffect(() => {
    if (focusSignal && ref.current) ref.current.focus();
  }, [focusSignal]);
  return jsx('input', {
    ref,
    className: 'hs-search',
    value,
    placeholder,
    spellCheck: false,
    onChange: (e) => onChange(e.target.value),
  });
}

