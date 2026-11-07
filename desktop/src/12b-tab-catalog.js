// ============================================================================
// §12b TAB: CATALOG (categories, generated parameter forms, target picker, preview/run, result tables)
// ============================================================================
const CATALOG_ESCALATION = 'More than 10 machines, an OU, all workstations, or a domain controller makes this a high-risk change';
const CATALOG_TARGET_PARAMS = new Set(['computers', 'ou']);

function catalogModuleLabel(e) {
  const m = String(e.module || '');
  if (!m.startsWith('gallery:')) return 'in-box';
  const [name, ver] = m.slice('gallery:'.length).split('@');
  return ver ? `${name} ${ver}` : name;
}

function catalogModuleName(e) {
  return String(e.module || '').slice('gallery:'.length).split('@')[0];
}

function ModuleBadge({ e }) {
  return jsx(Badge, { tone: e.module_installed === false ? 'yellow' : undefined, title: e.module_installed === false ? 'Module not installed' : undefined, children: catalogModuleLabel(e) });
}

async function catalogCopy(text, done) {
  const ok = await copyText(text);
  host.notify({ kind: ok ? 'success' : 'error', message: ok ? done : 'Copy failed' });
}

// PowerShell 5.1 can emit a single object where an array is expected.
function catalogAsList(x) {
  return Array.isArray(x) ? x : x ? [x] : [];
}

function catalogInstall(entry) {
  return runWrite(op('catalog_module_install', { name: catalogModuleName(entry) }), { title: `Install ${catalogModuleName(entry)}` });
}

function catalogDefaults(entry) {
  const v = {};
  list(entry.params).forEach((p) => {
    if (CATALOG_TARGET_PARAMS.has(p.name)) return;
    if (p.type === 'array') v[p.name] = list(p.default).join(', ');
    else if (p.type === 'boolean') v[p.name] = p.default === true;
    else v[p.name] = p.default === null || p.default === undefined ? '' : String(p.default);
  });
  return v;
}

// Returns { args } or { error }. Empty optional values are left out so the script default applies.
function catalogBuildParams(entry, values) {
  const args = {};
  for (const p of list(entry.params)) {
    if (CATALOG_TARGET_PARAMS.has(p.name)) continue;
    const raw = values[p.name];
    if (p.type === 'boolean') {
      // Never override a script default with false when the param declares no default.
      if (p.default !== null && p.default !== undefined) args[p.name] = !!raw;
      else if (raw === true) args[p.name] = true;
      continue;
    }
    const text = String(raw === undefined ? '' : raw).trim();
    if (!text) {
      if (p.required) return { error: `${p.name} is required.` };
      continue;
    }
    if (p.type === 'integer') {
      const n = Number(text);
      if (!Number.isInteger(n)) return { error: `${p.name} must be a whole number.` };
      if (typeof p.minimum === 'number' && n < p.minimum) return { error: `${p.name} must be at least ${p.minimum}.` };
      if (typeof p.maximum === 'number' && n > p.maximum) return { error: `${p.name} must be at most ${p.maximum}.` };
      args[p.name] = n;
    } else if (p.type === 'array') {
      args[p.name] = splitList(text);
    } else {
      args[p.name] = text;
    }
  }
  return { args };
}

function CatalogParamField({ p, value, onChange }) {
  const label = `${p.name}${p.required ? ' *' : ''}`;
  let input;
  if (p.type === 'boolean') {
    input = jsx('div', { children: jsx(Toggle, { on: value, onChange }) });
  } else if (Array.isArray(p.enum) && p.enum.length) {
    input = jsx('select', {
      className: 'hs-input',
      value: value === undefined ? '' : value,
      onChange: (e) => onChange(e.target.value),
      children: [p.required ? null : jsx('option', { value: '', children: '(default)' }, ''), ...p.enum.map((o) => jsx('option', { value: String(o), children: String(o) }, String(o)))],
    });
  } else if (p.type === 'integer') {
    input = jsx('input', {
      className: 'hs-input',
      type: 'number',
      step: 1,
      min: typeof p.minimum === 'number' ? p.minimum : undefined,
      max: typeof p.maximum === 'number' ? p.maximum : undefined,
      value: value === undefined ? '' : value,
      onChange: (e) => onChange(e.target.value),
    });
  } else if (p.type === 'array') {
    const items = splitList(value);
    input = jsxs('div', {
      className: 'hs-stack',
      children: [
        jsx(TextInput, { value, onChange, placeholder: 'comma-separated', mono: true }),
        items.length ? jsx('div', { className: 'hs-toolbar', children: items.map((t, i) => jsx(Badge, { children: t }, `${t}-${i}`)) }) : null,
      ],
    });
  } else {
    input = jsx(TextInput, { value, onChange });
  }
  return jsxs('div', {
    className: 'hs-stack',
    children: [
      jsx(Field, { label, children: input }),
      p.description ? jsx('div', { className: 'hs-muted hs-small', children: p.description }) : null,
    ],
  });
}

function catalogColumns(rows, entry) {
  const keys = [];
  rows.forEach((r) => Object.keys(r).forEach((k) => { if (!keys.includes(k)) keys.push(k); }));
  const declared = list(entry.columns).filter((c) => typeof c === 'string' && c);
  let cols = declared.length ? declared : keys;
  if (keys.includes('host')) cols = ['host', ...cols.filter((c) => c !== 'host')];
  return cols;
}

function catalogCell(v) {
  if (v === null || v === undefined || v === '') return jsx('span', { className: 'hs-muted', children: '—' });
  if (typeof v === 'object') return jsx('span', { className: 'hs-mono', children: JSON.stringify(v) });
  return String(v);
}

function catalogSummaryText(s) {
  if (!s) return '';
  if (typeof s === 'string') return s;
  if (typeof s === 'object' && typeof s.hosts === 'number') {
    const rest = Object.entries(s).filter(([k]) => !['hosts', 'ok', 'failed'].includes(k)).map(([k, v]) => `${v} ${k}`);
    return [`${s.hosts} hosts`, typeof s.ok === 'number' ? `${s.ok} ok` : null, typeof s.failed === 'number' ? `${s.failed} failed` : null, ...rest].filter(Boolean).join(' · ');
  }
  return Object.entries(s).map(([k, v]) => `${k}: ${typeof v === 'object' ? JSON.stringify(v) : v}`).join(' · ');
}

function CatalogResult({ entry, data }) {
  const payload = data === null || data === undefined ? {} : data;
  const rowsRaw = Array.isArray(payload.items) ? payload.items : Array.isArray(payload) ? payload : null;
  const errors = catalogAsList(payload.errors);
  const summary = catalogSummaryText(payload.summary);
  const errorStrip = errors.length
    ? jsx(Callout, {
        tone: 'red',
        icon: '⚠',
        children: jsx('div', {
          children: errors.map((e, i) => jsx('div', { className: 'hs-small', children: e && typeof e === 'object' ? `${e.host || '?'}: ${e.message || JSON.stringify(e)}` : String(e) }, i)),
        }),
      })
    : null;
  const summaryLine = summary ? jsx('div', { className: 'hs-muted hs-small', children: summary }) : null;
  if (!rowsRaw) {
    const rows = typeof payload === 'object' ? Object.entries(payload).filter(([k]) => k !== 'errors' && k !== 'summary').map(([k, v]) => [k, typeof v === 'object' && v !== null ? jsx('span', { className: 'hs-mono', children: JSON.stringify(v) }) : String(v)]) : [['value', String(payload)]];
    return jsxs('div', {
      className: 'hs-stack',
      children: [
        rows.length ? jsx(KV, { rows }) : jsx('div', { className: 'hs-muted', children: 'No data returned.' }),
        errorStrip,
        summaryLine,
        jsx(CatalogExport, { entry, rows: [], data: payload }),
      ],
    });
  }
  const rows = rowsRaw.map((r) => (r !== null && typeof r === 'object' && !Array.isArray(r) ? r : { value: r }));
  const cols = catalogColumns(rows, entry);
  return jsxs('div', {
    className: 'hs-stack',
    children: [
      rows.length
        ? jsx('div', {
            style: { overflowX: 'auto' },
            children: jsx(Table, {
              head: cols,
              children: rows.map((r, i) =>
                jsx('tr', {
                  children: cols.map((c) =>
                    jsx('td', {
                      children: c === 'host' && r.host
                        ? jsx('button', { type: 'button', className: 'hs-link', onClick: () => openDevice(r.host), children: String(r.host) })
                        : catalogCell(r[c]),
                    }, c),
                  ),
                }, i),
              ),
            }),
          })
        : jsx('div', { className: 'hs-muted', children: 'No rows returned.' }),
      errorStrip,
      summaryLine,
      jsx(CatalogExport, { entry, rows, cols, data: payload }),
    ],
  });
}

function CatalogExport({ entry, rows, cols, data }) {
  const exportCsv = async () => {
    if (!cols || !rows.length) return;
    const text = [cols.map(csvCell).join(','), ...rows.map((r) => cols.map((c) => csvCell(r[c])).join(','))].join('\n');
    await saveText(`${entry.id}.csv`, text);
  };
  return jsxs('div', {
    className: 'hs-toolbar',
    children: [
      cols ? jsx(Btn, { small: true, onClick: exportCsv, disabled: !rows.length, children: 'Export CSV' }) : null,
      jsx(Btn, { small: true, onClick: () => catalogCopy(pretty(data), 'JSON copied'), children: 'Copy JSON' }),
    ],
  });
}

// Target picker: chips for the selected devices, a typed list, an OU, or every workstation.
function CatalogTargetPicker({ mode, onMode, selected, onSelected, typed, onTyped, ou, onOu, writes }) {
  return jsxs('div', {
    className: 'hs-stack',
    children: [
      jsx(Seg, {
        value: mode,
        onChange: onMode,
        options: [['selected', `Selected devices (${selected.length})`], ['computers', 'Computers'], ['ou', 'OU'], ['all', 'All workstations']],
      }),
      mode === 'selected'
        ? selected.length
          ? jsx('div', {
              className: 'hs-toolbar',
              children: selected.map((n) => jsx(Chip, { on: true, onClick: () => onSelected(selected.filter((x) => x !== n)), children: `${n} ×` }, n)),
            })
          : jsx('div', { className: 'hs-muted hs-small', children: 'No devices selected. Tick devices in the Fleet tab, or pick another target.' })
        : null,
      mode === 'computers' ? jsx(TextInput, { value: typed, onChange: onTyped, placeholder: 'PC-01, PC-02', mono: true }) : null,
      mode === 'ou' ? jsx(TextInput, { value: ou, onChange: onOu, placeholder: 'OU=Workstations,DC=corp,DC=example', mono: true }) : null,
      mode === 'all' ? jsx('div', { className: 'hs-muted hs-small', children: 'Every enabled workstation in the domain.' }) : null,
      writes ? jsx(Callout, { tone: 'yellow', icon: '⚠', children: CATALOG_ESCALATION }) : null,
    ],
  });
}

// The shared form and actions. Used inline by CatalogTab and inside CatalogRunDialog.
function CatalogRunner({ entry, computers, inDialog }) {
  const endpoint = entry.target === 'endpoint';
  const writes = entry.tier !== 'R';
  const preset = list(computers);
  const [values, setValues] = useState(() => catalogDefaults(entry));
  const [selected, setSelected] = useState(() => (preset.length ? preset : $fleetSelection.get()));
  const [mode, setMode] = useState(() => (preset.length || $fleetSelection.get().length ? 'selected' : 'computers'));
  const [typed, setTyped] = useState('');
  const [ou, setOu] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const [result, setResult] = useState(null);
  const [preview, setPreview] = useState(null);
  const params = list(entry.params).filter((p) => !CATALOG_TARGET_PARAMS.has(p.name));

  const build = () => {
    const built = catalogBuildParams(entry, values);
    if (built.error) return { error: built.error };
    const args = built.args;
    if (endpoint) {
      if (mode === 'selected') {
        if (!selected.length) return { error: 'Select at least one device.' };
        args.computers = selected;
      } else if (mode === 'computers') {
        const names = splitList(typed);
        if (!names.length) return { error: 'Enter at least one computer name.' };
        args.computers = names;
      } else if (mode === 'ou') {
        if (!ou.trim()) return { error: 'Enter an OU distinguished name.' };
        args.ou = ou.trim();
      }
    }
    return { args };
  };

  const doRead = async () => {
    const b = build();
    if (b.error) return setError({ message: b.error });
    setError(null);
    setBusy(true);
    setResult(null);
    const res = await api.read(op(`cat.${entry.id}`, b.args));
    setBusy(false);
    if (res.ok) setResult(res.data);
    else setError(res.error);
  };
  const doPreview = async () => {
    const b = build();
    if (b.error) return setError({ message: b.error });
    setError(null);
    setResult(null);
    setPreview({ res: null, args: b.args });
    const res = await api.preview(op(`cat.${entry.id}`, b.args));
    setPreview({ res, args: b.args });
  };
  const doRun = async () => {
    const b = build();
    if (b.error) return setError({ message: b.error });
    setError(null);
    setPreview(null);
    const out = await runWrite(op(`cat.${entry.id}`, b.args), {
      title: entry.title,
      destructive: !!entry.destructive,
      onDone: (data) => {
        const failed = catalogAsList(data && data.errors).length;
        if (failed) host.notify({ kind: 'warning', message: `${entry.title}: finished with ${failed} failed host${failed === 1 ? '' : 's'}. See the results.` });
        // The confirm dialog replaced this one, so the dialog path shows results in a new dialog.
        if (inDialog) openDialog(CatalogResultDialog, { entry, data });
        else setResult(data);
      },
    });
    if (out.state === 'error') setError(out.error);
  };
  const install = () => catalogInstall(entry);
  const needsInstall = entry.module_installed === false;
  return jsxs('div', {
    className: 'hs-stack',
    children: [
      needsInstall
        ? jsx(Callout, {
            tone: 'yellow',
            icon: '⚠',
            children: jsxs('div', { className: 'hs-toolbar', children: [jsx('span', { children: `Requires module ${catalogModuleLabel(entry)}, which is not installed.` }), jsx(Btn, { small: true, kind: 'primary', onClick: install, children: 'Install' })] }),
          })
        : null,
      endpoint
        ? jsx(CatalogTargetPicker, { mode, onMode: setMode, selected, onSelected: setSelected, typed, onTyped: setTyped, ou, onOu: setOu, writes: entry.tier === 'W' })
        : jsx('div', { className: 'hs-muted hs-small', children: 'Runs on the domain controller.' }),
      params.map((p) => jsx(CatalogParamField, { p, value: values[p.name], onChange: (v) => setValues({ ...values, [p.name]: v }) }, p.name)),
      error ? jsx(ErrorBox, { error }) : null,
      jsx('div', {
        className: 'hs-toolbar',
        children: writes
          ? [
              jsx(Btn, { onClick: doPreview, disabled: busy, children: 'Preview' }, 'pv'),
              jsx(Btn, { kind: entry.destructive ? 'solid-danger' : 'primary', onClick: doRun, disabled: busy || needsInstall, children: 'Run' }, 'run'),
            ]
          : jsx(Btn, { kind: 'primary', onClick: doRead, disabled: busy || needsInstall, children: busy ? 'Running…' : 'Run' }),
      }),
      busy ? jsx(Spinner, { label: 'Running…' }) : null,
      preview ? jsx(PreviewBody, { q: { res: preview.res }, args: preview.args }) : null,
      result !== null ? jsx(CatalogResult, { entry, data: result }) : null,
    ],
  });
}

function CatalogEntryDetail({ entry }) {
  return jsxs('div', {
    className: 'hs-stack',
    children: [
      jsxs('div', {
        className: 'hs-toolbar',
        children: [
          jsx('b', { children: entry.title }),
          jsx(TierTag, { tier: entry.tier }),
          jsx(Badge, { children: entry.target === 'dc' ? 'DC' : 'Endpoints' }),
          jsx(ModuleBadge, { e: entry }),
        ],
      }),
      entry.description ? jsx('p', { className: 'hs-p', children: entry.description }) : null,
      jsx(KV, {
        rows: [
          ['Id', jsxs('span', { className: 'hs-nowrap', children: [jsx('span', { className: 'hs-mono', children: entry.id }), ' ', jsx(Btn, { small: true, kind: 'ghost', onClick: () => catalogCopy(entry.id, 'Id copied'), children: 'Copy' })] })],
          entry.source ? ['Source', entry.source] : null,
          ['Module', catalogModuleLabel(entry) + (entry.module_installed === false ? ' (not installed)' : '')],
        ],
      }),
    ],
  });
}

function catalogMatches(e, text) {
  if (!text) return true;
  return [e.id, e.title, e.description, ...list(e.tags)].some((v) => String(v || '').toLowerCase().includes(text));
}

function CatalogTab() {
  const cat = useCatalog();
  const handed = useValue($catalogComputers);
  // Take the handed-over computers once, then clear the shared atom so they never outlive this visit.
  const [preset, setPreset] = useState([]);
  useEffect(() => {
    if (handed.length) {
      setPreset(handed);
      $catalogComputers.set([]);
    }
  }, [handed]);
  useEffect(() => () => $catalogComputers.set([]), []);
  const [category, setCategory] = useState('');
  const [query, setQuery] = useState('');
  const [picked, setPicked] = useState(null);
  const data = cat.res && cat.res.ok ? cat.res.data || {} : null;
  const items = data ? list(data.items) : [];
  const text = query.trim().toLowerCase();
  const rows = items.filter((e) => (!category || e.category === category) && catalogMatches(e, text));
  const entry = items.find((e) => e.id === picked) || null;
  return jsx(Pending, {
    q: cat,
    label: 'Loading catalog…',
    children: () =>
      jsxs('div', {
        className: 'hs-grid2',
        children: [
          jsxs('div', {
            children: [
              jsxs('div', {
                className: 'hs-toolbar',
                children: [
                  jsx(Chip, { on: !category, onClick: () => setCategory(''), children: `All (${items.length})` }),
                  ...list(data.categories).map((c) => jsx(Chip, { on: category === c.name, onClick: () => setCategory(c.name), children: `${c.name} (${c.count})` }, c.name)),
                ],
              }),
              jsx('div', { className: 'hs-toolbar', children: jsx(SearchBox, { value: query, onChange: setQuery, placeholder: 'Search id, title, tags, description' }) }),
              preset.length ? jsx(Callout, { tone: 'accent', children: `Selected devices: ${preset.join(', ')}` }) : null,
              jsx(Table, {
                head: ['Entry', 'Tier', 'Target', 'Module'],
                children: rows.length
                  ? rows.map((e) =>
                      jsxs('tr', {
                        className: `click${e.id === picked ? ' sel' : ''}`,
                        tabIndex: 0,
                        onClick: () => setPicked(e.id),
                        onKeyDown: (ev) => {
                          if (ev.target === ev.currentTarget && (ev.key === 'Enter' || ev.key === ' ')) {
                            ev.preventDefault();
                            setPicked(e.id);
                          }
                        },
                        children: [
                          jsx('td', { children: jsx('b', { children: e.title }) }),
                          jsx('td', { children: jsx(TierTag, { tier: e.tier }) }),
                          jsx('td', { children: jsx(Badge, { children: e.target === 'dc' ? 'DC' : 'Endpoints' }) }),
                          jsx('td', { children: jsx(ModuleBadge, { e }) }),
                        ],
                      }, e.id),
                    )
                  : jsx(EmptyRow, { cols: 4, text: 'No catalog entries match.' }),
              }),
            ],
          }),
          entry
            ? jsx(Card, {
                children: jsxs('div', {
                  className: 'hs-stack',
                  children: [jsx(CatalogEntryDetail, { entry }), jsx(CatalogRunner, { entry, computers: preset }, entry.id)],
                }),
              })
            : jsx(Card, { children: jsx('div', { className: 'hs-muted', children: 'Select a catalog entry to see its parameters and run it.' }) }),
        ],
      }),
  });
}

// entry may be a catalog id (from the Fleet drawer) or a full entry.
function CatalogRunDialog({ seq, entry, computers }) {
  const cat = useCatalog();
  const items = cat.res && cat.res.ok ? list((cat.res.data || {}).items) : [];
  const e = typeof entry === 'string' ? items.find((x) => x.id === entry) : entry;
  return jsx(Modal, {
    seq,
    title: e ? e.title : 'Run catalog entry',
    tier: e ? e.tier : undefined,
    opName: e ? `cat.${e.id}` : undefined,
    wide: true,
    footer: [closeButton(seq, 'Close')],
    children: e
      ? jsx(CatalogRunner, { entry: e, computers, inDialog: true })
      : cat.res && !cat.res.ok
        ? jsx(ErrorBox, { error: cat.res.error })
        : cat.res
          ? jsx('div', { className: 'hs-muted', children: `Catalog entry ${entry} was not found.` })
          : jsx(Spinner, { label: 'Loading catalog…' }),
  });
}

function CatalogResultDialog({ seq, entry, data }) {
  const failed = catalogAsList(data && data.errors).length;
  return jsx(Modal, {
    seq,
    title: failed ? `${entry.title}: finished with ${failed} failed` : `${entry.title}: results`,
    tier: entry.tier,
    opName: `cat.${entry.id}`,
    wide: true,
    footer: [closeButton(seq, 'Close')],
    children: jsx(CatalogResult, { entry, data }),
  });
}
