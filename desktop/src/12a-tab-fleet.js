// ============================================================================
// §12a TAB: FLEET (inventory table, filters, multi-select) AND THE DEVICE DRAWER
// ============================================================================
const FLEET_LOW_DISK_DEFAULT = 10;
const FLEET_PATCH_OLD_DAYS = 35;
const FLEET_CHIPS = [
  ['low_disk', 'Low disk'],
  ['reboot', 'Reboot pending'],
  ['patch_old', 'Patch > 35 d'],
  ['defender_off', 'Defender off'],
  ['bitlocker_off', 'BitLocker off'],
  ['rdp_no_nla', 'RDP no NLA'],
];
const FLEET_PREDICATES = {
  all: () => true,
  online: (c) => !!c.online,
  offline: (c) => !c.online,
  low_disk: (c, lowPct) => !!c.online && typeof c.c_free_pct === 'number' && c.c_free_pct < lowPct,
  reboot: (c) => !!c.pending_reboot,
  patch_old: (c) => !!c.online && typeof c.patch_age_days === 'number' && c.patch_age_days > FLEET_PATCH_OLD_DAYS,
  defender_off: (c) => c.defender_rt === false,
  bitlocker_off: (c) => c.bitlocker !== null && c.bitlocker !== undefined && c.bitlocker !== 'on',
  rdp_no_nla: (c) => !!c.rdp && c.nla === false,
};

// Opens a computer's drawer from anywhere (Overview, Catalog results). Switching tabs clears the drawer, so go first.
function openDevice(name) {
  if (!name) return;
  if ($tab.get() !== 'fleet') goTab('fleet');
  $device.set(String(name));
}

function closeDevice() {
  $device.set(null);
}

// The single entry point for "run a catalog entry on these computers".
function openCatalogRun({ computers, entry }) {
  if (entry) {
    openDialog(CatalogRunDialog, { entry, computers: list(computers) });
    return true;
  }
  return goTab('catalog', { catalog: { computers } });
}

function fleetMatches(c, text) {
  if (!text) return true;
  return [c.name, c.dns, c.user, c.ou].some((v) => String(v || '').toLowerCase().includes(text));
}

function setFleetFilter(patch) {
  $fleet.set({ ...$fleet.get(), ...patch });
}

function toggleSelected(name, on) {
  const cur = $fleetSelection.get();
  $fleetSelection.set(on ? (cur.includes(name) ? cur : [...cur, name]) : cur.filter((n) => n !== name));
}

function FlagBadge({ ok, on, off }) {
  if (ok === null || ok === undefined) return jsx('span', { className: 'hs-muted', children: '—' });
  return jsx(Badge, { tone: ok ? 'green' : 'red', children: ok ? on : off });
}

function DiskCell({ c, lowPct }) {
  if (typeof c.c_free_pct !== 'number') return jsx('span', { className: 'hs-muted', children: '—' });
  const low = c.c_free_pct < lowPct;
  return jsxs('span', {
    className: 'hs-nowrap',
    title: typeof c.c_free_gb === 'number' ? `${c.c_free_gb} GB free of ${c.c_size_gb} GB` : undefined,
    children: [
      jsx('span', { className: `hs-bar hs-bar-inline${low ? ' low' : ''}`, children: jsx('i', { style: { width: `${Math.max(0, Math.min(100, c.c_free_pct))}%` } }) }),
      jsx('span', { className: low ? 'hs-text-red' : undefined, children: `${c.c_free_pct}%` }),
    ],
  });
}

function FleetRow({ c, selected, open, lowPct }) {
  const stale = typeof c.patch_age_days === 'number' && c.patch_age_days > FLEET_PATCH_OLD_DAYS;
  return jsxs('tr', {
    className: `click${open ? ' sel' : ''}`,
    tabIndex: 0,
    onClick: () => openDevice(c.name),
    onKeyDown: (e) => {
      if (e.target === e.currentTarget && (e.key === 'Enter' || e.key === ' ')) {
        e.preventDefault();
        openDevice(c.name);
      }
    },
    children: [
      jsx('td', {
        onClick: (e) => e.stopPropagation(),
        children: jsx('input', { type: 'checkbox', checked: selected, 'aria-label': `Select ${c.name}`, onChange: (e) => toggleSelected(c.name, e.target.checked) }),
      }),
      jsx('td', { children: jsx('b', { children: c.name }) }),
      jsx('td', { className: 'hs-muted', children: c.os || '—' }),
      jsx('td', { children: jsxs('span', { className: 'hs-nowrap', children: [jsx(Dot, { tone: c.online ? 'good' : 'muted' }), ' ', c.online ? 'online' : 'offline'] }) }),
      jsx('td', { children: c.user || '—' }),
      jsx('td', { className: 'hs-muted hs-nowrap', children: typeof c.uptime_days === 'number' ? `${c.uptime_days} d` : '—' }),
      jsx('td', { children: jsx(DiskCell, { c, lowPct }) }),
      jsx('td', { className: stale ? 'hs-text-yellow hs-nowrap' : 'hs-muted hs-nowrap', children: typeof c.patch_age_days === 'number' ? `${c.patch_age_days} d` : '—' }),
      jsx('td', { children: c.pending_reboot ? jsx(Badge, { tone: 'yellow', title: list(c.reboot_reasons).join(', '), children: 'pending' }) : jsx('span', { className: 'hs-muted', children: '—' }) }),
      jsx('td', { children: jsx(FlagBadge, { ok: c.defender_rt, on: 'on', off: 'off' }) }),
      jsx('td', { children: c.bitlocker === null || c.bitlocker === undefined ? jsx('span', { className: 'hs-muted', children: '—' }) : jsx(Badge, { tone: c.bitlocker === 'on' ? 'green' : 'yellow', children: c.bitlocker }) }),
      jsx('td', { children: c.rdp ? jsx(Badge, { tone: c.nla === false ? 'red' : 'green', children: c.nla === false ? 'no NLA' : 'NLA' }) : jsx('span', { className: 'hs-muted', children: c.rdp === false ? 'off' : '—' }) }),
    ],
  });
}

function FleetTab() {
  const f = useValue($fleet);
  const selection = useValue($fleetSelection);
  const open = useValue($device);
  const fleet = useFleet();
  const monitoring = useMonitoring();
  const monSettings = monitoring.res && monitoring.res.ok ? (monitoring.res.data || {}).settings || {} : {};
  const lowPct = typeof monSettings.alert_disk_free_pct === 'number' ? monSettings.alert_disk_free_pct : FLEET_LOW_DISK_DEFAULT;
  const [busy, setBusy] = useState(false);
  const refresh = async () => {
    setBusy(true);
    const res = await api.fleet(true);
    setBusy(false);
    if (res.ok) queryClient.setQueryData(KEY.fleet, res);
    else host.notify({ kind: 'error', message: `Inventory refresh failed: ${res.error.message}` });
  };
  const data = fleet.res && fleet.res.ok ? fleet.res.data || {} : null;
  const items = data ? list(data.items) : [];
  const osOptions = Array.from(new Set(items.map((c) => c.os).filter(Boolean))).sort();
  const text = (f.query || '').trim().toLowerCase();
  const test = FLEET_PREDICATES[f.filter] || FLEET_PREDICATES.all;
  const rows = items.filter((c) => test(c, lowPct) && (!f.os || c.os === f.os) && fleetMatches(c, text));
  const selected = new Set(selection);
  const knownKey = items.map((c) => c.name).join('|');
  useEffect(() => {
    if (!data) return;
    const known = new Set(items.map((c) => c.name));
    const cur = $fleetSelection.get();
    if (cur.some((n) => !known.has(n))) $fleetSelection.set(cur.filter((n) => known.has(n)));
  }, [knownKey, !!data]);
  const visibleSelected = rows.filter((c) => selected.has(c.name)).map((c) => c.name);
  const hiddenCount = selection.length - visibleSelected.length;
  const allVisible = rows.length > 0 && rows.every((c) => selected.has(c.name));
  const toggleAll = (on) => {
    const visible = new Set(rows.map((c) => c.name));
    $fleetSelection.set(on ? Array.from(new Set([...selection, ...visible])) : selection.filter((n) => !visible.has(n)));
  };
  return jsxs('div', {
    children: [
      jsxs('div', {
        className: 'hs-toolbar',
        children: [
          jsx(Seg, { value: f.filter, onChange: (v) => setFleetFilter({ filter: v }), options: [['all', 'All'], ['online', 'Online'], ['offline', 'Offline']] }),
          jsx(SearchBox, { value: f.query || '', onChange: (v) => setFleetFilter({ query: v }), placeholder: 'Search name, user, OU…', focusSignal: useValue($focusSearch) }),
          jsxs('select', {
            className: 'hs-input hs-select',
            'aria-label': 'Operating system',
            value: f.os || '',
            onChange: (e) => setFleetFilter({ os: e.target.value }),
            children: [jsx('option', { value: '', children: 'All operating systems' }, ''), ...osOptions.map((o) => jsx('option', { value: o, children: o }, o))],
          }),
          jsx('span', { className: 'hs-grow' }),
          data && data.taken_at ? jsx(UpdatedAgo, { at: toDate(data.taken_at) ? toDate(data.taken_at).getTime() : 0 }) : null,
          jsx(Btn, { onClick: refresh, disabled: busy, children: busy ? 'Collecting…' : 'Refresh inventory' }),
        ],
      }),
      jsx('div', {
        className: 'hs-toolbar',
        children: FLEET_CHIPS.map(([key, label]) =>
          jsx(Chip, { on: f.filter === key, onClick: () => setFleetFilter({ filter: f.filter === key ? 'all' : key }), children: label }, key),
        ),
      }),
      selection.length
        ? jsxs('div', {
            className: 'hs-toolbar hs-selbar',
            children: [
              jsx('b', { children: hiddenCount > 0 ? `${selection.length} selected (${hiddenCount} hidden)` : `${selection.length} selected` }),
              jsx(Btn, { small: true, kind: 'primary', disabled: !visibleSelected.length, onClick: () => openCatalogRun({ computers: visibleSelected }), children: `Run catalog entry… (${visibleSelected.length})` }),
              jsx(Btn, { small: true, kind: 'ghost', onClick: () => $fleetSelection.set([]), children: 'Clear' }),
            ],
          })
        : null,
      jsx(Pending, {
        q: fleet,
        label: 'Collecting the fleet inventory (can take up to a minute)…',
        children: () =>
          jsxs('div', {
            children: [
              jsx(Card, {
                children: jsx(Table, {
                  head: [
                    jsx('input', { type: 'checkbox', checked: allVisible, 'aria-label': 'Select all visible computers', onChange: (e) => toggleAll(e.target.checked) }),
                    'Computer', 'OS', 'Status', 'User', 'Uptime', 'C: free', 'Patch age', 'Reboot', 'Defender', 'BitLocker', 'RDP',
                  ],
                  children: rows.length
                    ? rows.map((c) => jsx(FleetRow, { c, selected: selected.has(c.name), open: open === c.name, lowPct }, c.name))
                    : jsx(EmptyRow, { cols: 12, text: 'No computers match these filters' }),
                }),
              }),
              jsx('p', { className: 'hs-muted hs-small', children: `Showing ${num(rows.length)} of ${num(items.length)} computers.` }),
            ],
          }),
      }),
    ],
  });
}

// ---------------------------------------------------------------------------
// Dialogs
// ---------------------------------------------------------------------------
// Shows a built mstsc/msra command with Copy and Download .cmd. data: {command, cmd_file, filename, note}.
function CommandDialog({ seq, title, data }) {
  const copy = async () => {
    const ok = await copyText(String(data.command || ''));
    host.notify({ kind: ok ? 'info' : 'error', message: ok ? 'Command copied.' : 'Could not copy the command.' });
  };
  const download = async () => {
    const saved = await saveText(data.filename || 'hermes-remote.cmd', String(data.cmd_file || data.command || ''));
    host.notify({ kind: saved.ok ? 'info' : 'error', message: savedMessage(data.filename || 'Command file', saved) });
  };
  return jsx(Modal, {
    seq,
    title,
    wide: true,
    footer: [
      jsx(Btn, { onClick: copy, children: 'Copy' }, 'copy'),
      jsx(Btn, { onClick: download, children: 'Download .cmd' }, 'dl'),
      closeButton(seq),
    ],
    children: jsxs('div', {
      className: 'hs-stack',
      children: [
        jsx('div', { className: 'hs-whatif hs-mono', children: data.command }),
        data.note ? jsx('div', { className: 'hs-muted hs-small', children: data.note }) : null,
      ],
    }),
  });
}

function ShadowDialog({ seq, computer, session }) {
  const [control, setControl] = useState(true);
  const [consent, setConsent] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const title = `Shadow ${session.user} on ${shortHost(computer)}`;
  const submit = async () => {
    setBusy(true);
    setError(null);
    if (!consent) {
      // No-consent shadowing is an H decision: it must go through the confirm flow.
      closeDialog(seq);
      await runWrite(op('remote_shadow_command', { computer, session_id: session.id, control, consent: false }), {
        title,
        confirmLabel: 'Build command',
        quiet: true,
        onDone: (data) => openDialog(CommandDialog, { title, data }),
      });
      return;
    }
    const res = await api.remoteShadow(computer, { session_id: session.id, control, consent: true });
    setBusy(false);
    if (!res.ok) {
      setError(res.error);
      return;
    }
    closeDialog(seq);
    openDialog(CommandDialog, { title, data: res.data });
  };
  return jsx(Modal, {
    seq,
    title,
    description: 'Builds an mstsc /shadow command to run on your own computer.',
    footer: [
      jsx(Btn, { onClick: () => closeDialog(seq), disabled: busy, children: 'Cancel' }, 'cancel'),
      jsx(Btn, { kind: 'primary', onClick: submit, disabled: busy, children: busy ? 'Working…' : 'Build command' }, 'ok'),
    ],
    children: jsxs('div', {
      className: 'hs-stack',
      children: [
        jsxs('div', { className: 'hs-row', children: [jsx(Toggle, { on: control, onChange: setControl }), jsx('span', { children: control ? 'Take control of the session' : 'View only' })] }),
        jsxs('div', { className: 'hs-row', children: [jsx(Toggle, { on: consent, onChange: setConsent }), jsx('span', { children: consent ? 'Ask the user for consent first' : 'Do not ask for consent (needs approval)' })] }),
        consent ? null : jsx(Callout, { tone: 'red', icon: '⚠', children: 'The user will not be asked. This is a high-risk action and is written to the audit log.' }),
        error ? jsx(ErrorBox, { error }) : null,
      ],
    }),
  });
}

// A small form for a catalog write that needs typed arguments. fields: [{key, label, placeholder, number, value}].
function ParamDialog({ seq, title, entry, computers, fields, confirmLabel, body, doneMessage }) {
  const [vals, setVals] = useState(() => Object.fromEntries(fields.map((fl) => [fl.key, fl.value === undefined ? '' : String(fl.value)])));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const missing = fields.some((fl) => fl.required !== false && !String(vals[fl.key] || '').trim());
  const submit = async () => {
    if (missing || busy) return;
    const args = { computers };
    fields.forEach((fl) => {
      const v = String(vals[fl.key] || '').trim();
      if (v === '') return;
      args[fl.key] = fl.number ? Number(v) : v;
    });
    const o = op(`cat.${entry}`, args);
    setBusy(true);
    setError(null);
    // Check the decision first so a rejected request leaves the typed text in place.
    const d = await api.decision(o);
    if (!d.ok) {
      setBusy(false);
      setError(d.error);
      return;
    }
    closeDialog(seq);
    runWrite(o, { title, body, confirmLabel: confirmLabel || 'Continue', doneMessage });
  };
  return jsx(Modal, {
    seq,
    title,
    description: computers.map(shortHost).join(', '),
    footer: [
      jsx(Btn, { onClick: () => closeDialog(seq), children: 'Cancel' }, 'cancel'),
      jsx(Btn, { kind: 'primary', onClick: submit, disabled: missing || busy, children: confirmLabel || 'Continue' }, 'ok'),
    ],
    children: jsx('div', {
      className: 'hs-stack',
      children: [error ? jsx(ErrorBox, { error }, 'err') : null].concat(fields.map((fl, i) =>
        jsx(Field, {
          label: fl.label,
          children: jsx(TextInput, { value: vals[fl.key], onChange: (v) => setVals({ ...vals, [fl.key]: v }), placeholder: fl.placeholder, autoFocus: i === 0, onEnter: submit, type: fl.number ? 'number' : 'text' }),
        }, fl.key),
      )),
    }),
  });
}

function runFix(name, fix, label) {
  // Shadow policy needs an explicit level; 1 is full control with the user's consent.
  const shadow = fix === 'remote.set_shadow_policy';
  const args = shadow ? { computers: [name], Level: 1 } : { computers: [name] };
  return runWrite(op(`cat.${fix}`, args), {
    title: `Fix: ${label}`,
    body: shadow ? `Set the shadow policy on ${shortHost(name)} to level 1: full control, with the user's consent?` : `Apply "${label}" on ${shortHost(name)}?`,
    confirmLabel: 'Apply fix',
    doneMessage: `${label}: fixed on ${shortHost(name)}`,
  });
}

function logoffRemote(name, s) {
  return runWrite(op('cat.remote.logoff_session', { computers: [name], SessionId: s.id }), {
    title: 'Log off session',
    body: `Log off ${s.user} on ${shortHost(name)}? Unsaved work in their session is lost.`,
    confirmLabel: 'Log off',
    destructive: false,
    doneMessage: `${s.user} logged off ${shortHost(name)}`,
  });
}

async function offerAssist(name) {
  const res = await api.remoteAssist(name);
  if (!res.ok) {
    openDialog(ErrorDialog, { title: `Offer Remote Assistance to ${shortHost(name)}`, error: res.error });
    return;
  }
  openDialog(CommandDialog, { title: `Offer Remote Assistance to ${shortHost(name)}`, data: res.data });
}

function checkValueText(v) {
  if (v === null || v === undefined) return 'unknown';
  if (Array.isArray(v)) return v.length ? v.join(', ') : 'none';
  if (typeof v === 'boolean') return v ? 'yes' : 'no';
  return String(v);
}

// ---------------------------------------------------------------------------
// Drawer
// ---------------------------------------------------------------------------
function DeviceDrawerHost() {
  const name = useValue($device);
  return name ? jsx(DeviceDrawer, { name }, name) : null;
}

function MiniTable({ head, rows, empty }) {
  return jsx(Table, { head, children: rows.length ? rows : jsx(EmptyRow, { cols: head.length, text: empty }) });
}

function DeviceSummary({ name, detail }) {
  return jsx(Pending, {
    q: detail,
    label: `Reading ${shortHost(name)}…`,
    children: (d) =>
      jsxs('div', {
        children: [
          jsx('div', {
            className: 'hs-sec',
            children: jsx(KV, {
              rows: [
                ['Operating system', `${d.os || '—'}${d.build ? ` (${d.build})` : ''}`],
                ['OU', jsx('span', { className: 'hs-mono hs-tiny', children: d.ou || '—' })],
                ['Signed in', d.user || '—'],
                ['Last boot', d.last_boot ? `${fmtDate(d.last_boot)} (${d.uptime_days} d up)` : '—'],
                ['Memory', typeof d.ram_gb === 'number' ? `${d.ram_gb} GB` : '—'],
                ['C: drive', typeof d.c_free_gb === 'number' ? `${d.c_free_gb} of ${d.c_size_gb} GB free (${d.c_free_pct}%)` : '—'],
                ['Last patch', d.last_hotfix ? `${fmtDay(d.last_hotfix)} (${d.patch_age_days} d ago)` : '—'],
                ['Pending reboot', d.pending_reboot ? `Yes: ${list(d.reboot_reasons).join(', ') || 'unknown reason'}` : 'No'],
                ['Defender', d.defender_rt === null || d.defender_rt === undefined ? '—' : `${d.defender_rt ? 'on' : 'off'}${typeof d.defender_sig_age_days === 'number' ? `, signatures ${d.defender_sig_age_days} d old` : ''}`],
                ['BitLocker', d.bitlocker || '—'],
                ['Remote Desktop', d.rdp === null || d.rdp === undefined ? '—' : d.rdp ? `on, NLA ${d.nla ? 'required' : 'not required'}` : 'off'],
                ['Installed software', typeof d.software_count === 'number' ? num(d.software_count) : '—'],
                ['Local administrators', list(d.admins).length ? list(d.admins).join(', ') : '—'],
              ],
            }),
          }),
          jsxs('div', {
            className: 'hs-sec',
            children: [
              jsx('h4', { children: 'Top CPU' }),
              jsx(MiniTable, {
                head: ['Process', 'CPU s', 'Memory MB'],
                empty: 'None reported',
                rows: list(d.top_cpu).map((p) => jsxs('tr', { children: [jsx('td', { children: p.name }), jsx('td', { children: p.cpu_s }), jsx('td', { children: p.ws_mb })] }, `${p.name}-${p.pid}`)),
              }),
              jsx('h4', { style: { marginTop: 12 }, children: 'Top memory' }),
              jsx(MiniTable, {
                head: ['Process', 'CPU s', 'Memory MB'],
                empty: 'None reported',
                rows: list(d.top_mem).map((p) => jsxs('tr', { children: [jsx('td', { children: p.name }), jsx('td', { children: p.cpu_s }), jsx('td', { children: p.ws_mb })] }, `${p.name}-${p.pid}`)),
              }),
            ],
          }),
          jsxs('div', {
            className: 'hs-sec',
            children: [
              jsx('h4', { children: `Stopped automatic services (${list(d.stopped_auto_services).length})` }),
              jsx(MiniTable, {
                head: ['Service', 'Display name'],
                empty: 'All automatic services are running',
                rows: list(d.stopped_auto_services).map((s) => jsxs('tr', { children: [jsx('td', { className: 'hs-mono', children: s.name }), jsx('td', { className: 'hs-muted', children: s.display })] }, s.name)),
              }),
            ],
          }),
          jsxs('div', {
            className: 'hs-sec',
            children: [
              jsx('h4', { children: 'Recent errors (24 h)' }),
              jsx(MiniTable, {
                head: ['Time', 'Source', 'Message'],
                empty: 'No errors logged',
                rows: list(d.recent_errors).map((e, i) =>
                  jsxs('tr', { children: [jsx('td', { className: 'hs-nowrap hs-muted', children: fmtTime(e.time) }), jsx('td', { children: `${e.log}/${e.source} ${e.id}` }), jsx('td', { className: 'hs-small', children: e.message })] }, i),
                ),
              }),
            ],
          }),
        ],
      }),
  });
}

function DeviceRemote({ name }) {
  const sessions = useApi(KEY.remoteSessions(name), () => api.remoteSessions([name]), { refetchInterval: POLL.sessions, staleTime: 15000 });
  const check = useApi(KEY.remoteCheck(name), () => api.remoteCheck(name), { staleTime: 30000 });
  const items = sessions.res && sessions.res.ok ? list(sessions.res.data.items) : [];
  const toolbox = [
    ['Send message', () => openDialog(ParamDialog, {
      title: 'Send message', entry: 'remote.send_message', computers: [name], confirmLabel: 'Send',
      body: `Show this message to everyone logged on to ${shortHost(name)}?`,
      fields: [{ key: 'Message', label: 'Message', placeholder: 'Up to 255 characters' }, { key: 'Seconds', label: 'Seconds on screen', number: true, value: 60 }],
    })],
    ['Lock', () => runWrite(op('cat.remote.lock_workstation', { computers: [name] }), { title: 'Lock sessions', body: `Disconnect and lock the active sessions on ${shortHost(name)}? Programs keep running.`, confirmLabel: 'Lock', doneMessage: `Locked ${shortHost(name)}` })],
    ['Restart', () => openDialog(ParamDialog, {
      title: 'Restart computer', entry: 'remote.restart_computer', computers: [name], confirmLabel: 'Continue',
      body: `Restart ${shortHost(name)}?`,
      fields: [{ key: 'Reason', label: 'Reason shown to users', placeholder: 'Maintenance' }, { key: 'DelaySeconds', label: 'Delay in seconds', number: true, value: 300 }],
    })],
    ['gpupdate', () => runWrite(op('cat.maint.gpupdate', { computers: [name], Force: true }), { title: 'Refresh Group Policy', body: `Run gpupdate /force on ${shortHost(name)}?`, confirmLabel: 'Run gpupdate', doneMessage: `gpupdate sent to ${shortHost(name)}` })],
    ['Restart service', () => openDialog(ParamDialog, {
      title: 'Restart service', entry: 'maint.restart_service', computers: [name], confirmLabel: 'Continue',
      body: `Restart this service on ${shortHost(name)}?`,
      fields: [{ key: 'Name', label: 'Service name', placeholder: 'Spooler' }],
    })],
  ];
  return jsxs('div', {
    children: [
      jsxs('div', {
        className: 'hs-sec',
        children: [
          jsx('h4', { children: 'Connect' }),
          jsx('div', { className: 'hs-actions', children: jsx(Btn, { kind: 'primary', small: true, onClick: () => connectRdp(name), children: 'Connect (.rdp)' }) }),
        ],
      }),
      jsxs('div', {
        className: 'hs-sec',
        children: [
          jsx('h4', { children: 'Sessions' }),
          !sessions.res
            ? jsx(Spinner, { label: 'Looking for sessions…' })
            : !sessions.res.ok
              ? jsx(ErrorBox, { error: sessions.res.error })
              : jsxs('div', {
                  children: [
                    jsx(UnreachableCallout, { errors: sessions.res.data.errors, what: 'sessions' }),
                    jsx(Table, {
                      head: ['User', 'State', 'Idle', ''],
                      children: items.length
                        ? items.map((s) =>
                            jsxs('tr', {
                              children: [
                                jsx('td', { children: jsx('b', { children: s.user || '—' }) }),
                                jsx('td', { children: jsx(Badge, { tone: s.state === 'active' ? 'green' : 'yellow', children: s.state }) }),
                                jsx('td', { className: 'hs-muted', children: s.idle || '—' }),
                                jsx('td', {
                                  children: jsxs('div', {
                                    className: 'hs-actions',
                                    children: [
                                      jsx(Btn, { small: true, onClick: () => openDialog(ShadowDialog, { computer: name, session: s }), children: 'Shadow' }),
                                      jsx(Btn, { small: true, onClick: () => offerAssist(name), children: 'Offer RA' }),
                                      jsx(Btn, { small: true, kind: 'danger', onClick: () => logoffRemote(name, s), children: 'Log off' }),
                                    ],
                                  }),
                                }),
                              ],
                            }, `${s.host}-${s.id}`),
                          )
                        : jsx(EmptyRow, { cols: 4, text: 'Nobody is signed in' }),
                    }),
                  ],
                }),
        ],
      }),
      jsxs('div', {
        className: 'hs-sec',
        children: [
          jsx('h4', { children: 'Remote access checks' }),
          jsx(Pending, {
            q: check,
            label: 'Checking remote access settings…',
            children: (d) =>
              jsx('div', {
                children: list(d.checks).map((c) =>
                  jsxs('div', {
                    className: 'hs-row',
                    children: [
                      jsx(Dot, { tone: c.ok === true ? 'good' : c.ok === false ? 'bad' : 'muted' }),
                      jsxs('span', { children: [c.label, jsx('span', { className: 'hs-muted hs-small', children: ` · ${checkValueText(c.value)}` })] }),
                      jsx('span', { className: 'hs-grow' }),
                      c.ok === false && c.fix ? jsx(Btn, { small: true, onClick: () => runFix(name, c.fix, c.label), children: 'Fix' }) : null,
                    ],
                  }, c.key),
                ),
              }),
          }),
        ],
      }),
      jsxs('div', {
        className: 'hs-sec',
        children: [jsx('h4', { children: 'Toolbox' }), jsx('div', { className: 'hs-actions', children: toolbox.map(([label, run]) => jsx(Btn, { small: true, onClick: run, children: label }, label)) })],
      }),
    ],
  });
}

function DeviceRun({ name }) {
  const [text, setText] = useState('');
  const catalog = useCatalog();
  const t = text.trim().toLowerCase();
  const entries = catalog.res && catalog.res.ok
    ? list(catalog.res.data.items).filter((e) => e.target === 'endpoint' && (!t || [e.id, e.title, e.category, ...list(e.tags)].some((v) => String(v || '').toLowerCase().includes(t))))
    : [];
  return jsxs('div', {
    className: 'hs-sec',
    children: [
      jsx('div', { className: 'hs-toolbar', children: jsx(SearchBox, { value: text, onChange: setText, placeholder: 'Search catalog entries…' }) }),
      jsx(Pending, {
        q: catalog,
        label: 'Loading the catalog…',
        children: () =>
          entries.length
            ? jsx('div', {
                children: entries.map((e) =>
                  jsxs('div', {
                    className: 'hs-row hs-clickrow',
                    role: 'button',
                    tabIndex: 0,
                    onClick: () => openCatalogRun({ computers: [name], entry: e.id }),
                    onKeyDown: (ev) => { if (ev.key === 'Enter') openCatalogRun({ computers: [name], entry: e.id }); },
                    children: [
                      jsxs('span', { style: { minWidth: 0 }, children: [jsx('b', { children: e.title }), jsx('div', { className: 'hs-muted hs-small', children: e.category })] }),
                      jsx('span', { className: 'hs-grow' }),
                      jsx(TierTag, { tier: e.tier }),
                    ],
                  }, e.id),
                ),
              })
            : jsx('span', { className: 'hs-muted', children: 'No endpoint entries match' }),
      }),
    ],
  });
}

function DeviceHistory({ name }) {
  const query = { limit: 200 };
  const q = useApi(KEY.audit(query), () => api.audit(query), { staleTime: 15000 });
  const rows = q.res && q.res.ok ? list(q.res.data.items).filter((a) => String(a.target || '').split(',').some((t) => t.trim() && sameHost(t.trim(), name))) : [];
  return jsx('div', {
    className: 'hs-sec',
    children: jsx(Pending, {
      q,
      label: 'Reading the audit log…',
      children: () =>
        jsx(Table, {
          head: ['Time', 'Action', 'Tier', 'Result'],
          children: rows.length
            ? rows.map((a) =>
                jsxs('tr', {
                  className: 'click',
                  onClick: () => openDialog(AuditRowDialog, { row: a }),
                  children: [
                    jsx('td', { className: 'hs-mono hs-muted hs-nowrap', children: fmtDate(a.ts) }),
                    jsx('td', { className: 'hs-mono', children: a.tool }),
                    jsx('td', { children: jsx(TierTag, { tier: a.tier }) }),
                    jsx('td', { children: jsx(AuditDecision, { row: a }) }),
                  ],
                }, a.id),
              )
            : jsx(EmptyRow, { cols: 4, text: 'No audit rows for this computer in the latest 200' }),
        }),
    }),
  });
}

function DeviceDrawer({ name }) {
  const [tab, setTab] = useState('summary');
  const fleet = useFleet();
  const detail = useApi(KEY.fleetDevice(name), () => api.fleetDevice(name), { staleTime: 30000 });
  const row = fleet.res && fleet.res.ok ? list(fleet.res.data.items).find((c) => sameHost(c.name, name)) : null;
  return jsxs('aside', {
    className: 'hs-drawer hs-drawer-wide',
    children: [
      jsxs('div', {
        className: 'hs-dh',
        children: [
          jsx('div', { className: 'hs-avatar', children: initials(name) }),
          jsxs('div', {
            style: { flex: 1, minWidth: 0 },
            children: [
              jsx('b', { children: name }),
              jsxs('div', { className: 'hs-muted', children: [jsx(Dot, { tone: row && row.online ? 'good' : 'muted' }), ' ', row ? (row.online ? 'online' : row.error ? `offline: ${row.error}` : 'offline') : 'status unknown', row && row.dns ? ` · ${row.dns}` : ''] }),
            ],
          }),
          jsx('button', { type: 'button', className: 'hs-ghost', title: 'Close', onClick: closeDevice, children: '✕' }),
        ],
      }),
      jsx('div', {
        className: 'hs-sec',
        children: jsx(Seg, { value: tab, onChange: setTab, options: [['summary', 'Summary'], ['remote', 'Remote'], ['run', 'Run'], ['history', 'History']] }),
      }),
      tab === 'summary' ? jsx(DeviceSummary, { name, detail }) : null,
      tab === 'remote' ? jsx(DeviceRemote, { name }) : null,
      tab === 'run' ? jsx(DeviceRun, { name }) : null,
      tab === 'history' ? jsx(DeviceHistory, { name }) : null,
    ],
  });
}
