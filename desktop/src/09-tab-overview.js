// ============================================================================
// §9 TAB: OVERVIEW
// ============================================================================
const SECTION_LABEL = { domain: 'Domain', dc_health: 'DC health', sessions: 'RDP sessions', gpo_health: 'GPO health', backups: 'Backups' };

function SectionErrors({ errors }) {
  const entries = Object.entries(errors || {});
  if (!entries.length) return null;
  return jsx('div', {
    className: 'hs-stack',
    style: { marginBottom: 12 },
    children: entries.map(([key, e]) =>
      jsx(Callout, {
        tone: 'yellow',
        icon: '⚠',
        children: jsxs('div', {
          children: [jsx('b', { children: `${SECTION_LABEL[key] || key}: ` }), `${e.type} · ${e.message}`, e.hint ? jsx('div', { className: 'hs-muted hs-small', children: e.hint }) : null],
        }),
      }, key),
    ),
  });
}

const FLEET_LOADING = 'Collecting the fleet inventory (can take up to a minute)…';

function fleetGo(filter, extra) {
  return () => goTab('fleet', { fleet: { filter, ...(extra || {}) } });
}

function fleetNum(fleet, pick) {
  if (!fleet.res) return '…';
  if (!fleet.res.ok) return '—';
  return pick((fleet.res.data || {}).summary || {});
}

function patchPct(s) {
  return s && s.online > 0 ? Math.round((100 * (s.patch_compliant || 0)) / s.online) : null;
}

function OverviewKpis({ data, fleet, monitoring, alertsRef }) {
  const k = data.kpis || {};
  const usersTotal = k.users;
  const usersEnabled = k.users_enabled !== undefined && k.users_enabled !== null ? k.users_enabled : usersTotal - (k.users_disabled || 0);
  const fs = fleet.res && fleet.res.ok ? ((fleet.res.data || {}).summary || {}) : null;
  const pct = patchPct(fs);
  const alerts = monitoring.res && monitoring.res.ok ? list((monitoring.res.data || {}).open_alerts).length : null;
  const backupsTotal = k.backups_total;
  return jsxs('div', {
    className: 'hs-kpis',
    children: [
      jsx(StatTile, { label: 'Users enabled', value: `${num(usersEnabled)} / ${num(usersTotal)}`, sub: `${num(k.users_disabled)} disabled`, onClick: () => goTab('users') }),
      jsx(StatTile, {
        label: 'Computers online',
        value: fleet.res ? (fs ? `${num(fs.online)} / ${num(fs.total)}` : '—') : '…',
        sub: fs ? `${num(fs.offline)} offline` : fleet.res ? 'inventory failed' : 'collecting…',
        onClick: fleetGo('offline'),
      }),
      jsx(StatTile, {
        label: 'Patch compliance',
        value: pct === null ? (fleet.res ? '—' : '…') : `${pct}%`,
        sub: 'patched within 35 days',
        tone: pct === null ? null : pct < 70 ? 'danger' : pct < 90 ? 'warning' : null,
        onClick: fleetGo('patch_old'),
      }),
      jsx(StatTile, {
        label: 'Pending reboots',
        value: fleetNum(fleet, (s) => num(s.pending_reboot)),
        sub: 'computers',
        tone: fs && fs.pending_reboot ? 'warning' : null,
        onClick: fleetGo('reboot'),
      }),
      jsx(StatTile, {
        label: 'Backups OK',
        value: backupsTotal === null || backupsTotal === undefined ? '—' : `${num(k.backups_ok)} / ${num(backupsTotal)}`,
        sub: k.backups_bad ? `${num(k.backups_bad)} need attention` : 'servers',
        tone: k.backups_bad ? 'danger' : null,
        onClick: () => goTab('backups'),
      }),
      jsx(StatTile, {
        label: 'GPOs needing attention',
        value: num(k.gpos_needing_attention),
        sub: `of ${num(k.gpos)}`,
        tone: k.gpos_needing_attention ? 'warning' : null,
        onClick: () => goTab('gpo'),
      }),
      jsx(StatTile, {
        label: 'Open alerts',
        value: alerts === null ? (monitoring.res ? '—' : '…') : String(alerts),
        sub: 'monitoring',
        tone: alerts ? 'danger' : null,
        onClick: () => { if (alertsRef.current) alertsRef.current.scrollIntoView({ behavior: 'smooth', block: 'start' }); },
      }),
    ],
  });
}

// Fleet-dependent card body: spinner while loading, ErrorBox on failure, children(data) otherwise.
function FleetBody({ fleet, children }) {
  return jsx(Pending, { q: fleet, label: FLEET_LOADING, children });
}

function orderedBuckets(obj, keys) {
  return keys.map((key) => ({ label: key, value: num0((obj || {})[key]) }));
}

function num0(v) {
  return typeof v === 'number' && Number.isFinite(v) ? v : 0;
}

const PATCH_BUCKETS = ['<7', '7-35', '35-90', '>90', 'unknown'];
const SEEN_BUCKETS = ['<1d', '1-7d', '7-30d', '30-90d', '>90d', 'never'];
// Bucket colours say how worried to be: fresh is green, old is amber then red, unknown is grey.
const PATCH_TONE = { '<7': 'success', '7-35': 'success', '35-90': 'warning', '>90': 'danger', unknown: 'muted' };
const SEEN_TONE = { '<1d': 'success', '1-7d': 'success', '7-30d': null, '30-90d': 'warning', '>90d': 'danger', never: 'muted' };

function toned(buckets, tones) {
  return buckets.map((b) => ({ ...b, tone: tones[b.label] }));
}
const DISK_DEFAULT_PCT = 10;

function diskThreshold(monitoring) {
  const m = monitoring.res && monitoring.res.ok ? monitoring.res.data || {} : {};
  const v = (m.settings || {}).alert_disk_free_pct;
  return typeof v === 'number' && v > 0 ? v : DISK_DEFAULT_PCT;
}

function FleetCharts({ fleet, diskPct }) {
  return jsx(Card, {
    title: 'Fleet',
    sub: 'workstations and servers',
    children: jsx(FleetBody, {
      fleet,
      children: (d) => {
        const s = d.summary || {};
        const osData = Object.entries(s.os_mix || {})
          .sort((a, b) => b[1] - a[1])
          .map(([label, value]) => ({ label, value, onClick: fleetGo('all', { os: label }) }));
        const patch = toned(orderedBuckets(s.patch_age_buckets, PATCH_BUCKETS), PATCH_TONE).map((b) => (b.label === '35-90' || b.label === '>90' ? { ...b, onClick: fleetGo('patch_old') } : b));
        const lowDisk = list(d.items)
          .filter((i) => i.online && typeof i.c_free_pct === 'number')
          .sort((a, b) => a.c_free_pct - b.c_free_pct)
          .slice(0, 8)
          .map((i) => ({
            label: i.name,
            value: i.c_free_pct,
            display: `${i.c_free_pct}% free`,
            tone: i.c_free_pct < diskPct ? 'danger' : null,
            onClick: () => goTab('fleet', { fleet: { query: i.name } }),
          }));
        return jsxs('div', {
          className: 'hs-grid3',
          children: [
            jsxs('div', { children: [jsx('div', { className: 'hs-label', children: 'Operating systems' }), osData.length ? jsx(Donut, { data: osData, center: String(num0(s.total)), title: 'Operating systems' }) : jsx('div', { className: 'hs-muted', children: 'No computers' })] }),
            jsxs('div', { children: [jsx('div', { className: 'hs-label', children: 'Last logon' }), jsx(Histogram, { data: toned(orderedBuckets(s.last_seen_buckets, SEEN_BUCKETS), SEEN_TONE), title: 'Computers by last logon' })] }),
            jsxs('div', { children: [jsx('div', { className: 'hs-label', children: 'Patch age (days)' }), jsx(Histogram, { data: patch, title: 'Computers by days since last patch' })] }),
            jsxs('div', {
              className: 'hs-span3',
              children: [
                jsx('div', { className: 'hs-label', children: 'Lowest free space on C:' }),
                lowDisk.length ? jsx(BarList, { data: lowDisk, max: 100, title: 'Lowest free space on C:' }) : jsx('div', { className: 'hs-muted', children: 'No disk data' }),
              ],
            }),
          ],
        });
      },
    }),
  });
}

function IdentityCard({ data }) {
  const k = data.kpis || {};
  const total = num0(k.users);
  const locked = num0(k.users_locked);
  const disabled = num0(k.users_disabled);
  const enabled = k.users_enabled !== undefined && k.users_enabled !== null ? k.users_enabled : Math.max(0, total - disabled);
  const users = (patch) => () => goTab('users', { users: patch });
  const parts = [
    { label: 'Enabled', value: num0(enabled), onClick: users({ status: 'any' }) },
    { label: 'Disabled', value: disabled, onClick: users({ status: 'disabled' }) },
    { label: 'Locked out', value: locked, onClick: users({ status: 'locked' }) },
    { label: 'Stale', value: num0(k.users_stale), onClick: users({ stale: true }) },
    { label: 'Never expires', value: num0(k.users_never_expire) },
  ];
  return jsx(Card, {
    title: 'Identity',
    sub: `${num(k.users)} user accounts · ${num(k.computers_stale)} stale computers`,
    children: jsxs('div', {
      className: 'hs-stack',
      children: [
        total > 0
          ? jsx(StackedBar, { data: parts, title: 'Account hygiene (counts overlap)' })
          : jsx('div', { className: 'hs-muted', children: 'No user data' }),
        jsx('div', { className: 'hs-muted hs-small', children: 'Account hygiene (counts overlap)' }),
        jsxs('div', {
          className: 'hs-kpis',
          children: [
            jsx(StatTile, {
              label: 'Passwords expiring',
              value: num(k.passwords_expiring),
              sub: 'soon',
              tone: k.passwords_expiring ? 'warning' : null,
              onClick: () => goTab('users', { users: { expiring: true } }),
            }),
            jsx(StatTile, {
              label: 'Stale computers',
              value: num(k.computers_stale),
              sub: 'no recent logon',
              tone: k.computers_stale ? 'warning' : null,
              onClick: () => goTab('rdp', { rdpView: 'hosts' }),
            }),
          ],
        }),
      ],
    }),
  });
}

function SecurityCard({ fleet }) {
  return jsx(Card, {
    title: 'Security posture',
    sub: 'computers that need a look',
    children: jsx(FleetBody, {
      fleet,
      children: (d) => {
        const s = d.summary || {};
        const tile = (label, n, filter) =>
          jsx(StatTile, { label, value: num(n), sub: 'computers', tone: n ? 'danger' : 'success', onClick: fleetGo(filter) });
        return jsxs('div', {
          className: 'hs-kpis',
          children: [tile('Defender off', s.defender_off, 'defender_off'), tile('BitLocker off', s.bitlocker_off, 'bitlocker_off'), tile('RDP without NLA', s.rdp_no_nla, 'rdp_no_nla')],
        });
      },
    }),
  });
}

function InfrastructureCard({ data }) {
  const k = data.kpis || {};
  const total = num0(k.gpos);
  const attention = num0(k.gpos_needing_attention);
  const unlinked = Math.min(num0(k.gpos_unlinked), attention);
  const gpoData = [
    { label: 'Healthy', value: Math.max(0, total - attention), tone: 'success', onClick: () => goTab('gpo') },
    { label: 'Unlinked', value: unlinked, tone: 'warning', onClick: () => goTab('gpo') },
    { label: 'Other issues', value: attention - unlinked, tone: 'danger', onClick: () => goTab('gpo') },
  ].filter((d) => d.value > 0);
  const backups = list(data.backups)
    .filter((b) => typeof b.age_hours === 'number')
    .sort((a, b) => b.age_hours - a.age_hours)
    .slice(0, 8)
    .map((b) => ({ label: shortHost(b.host), value: b.age_hours, display: ageText(b.age_hours), tone: b.state === 'bad' ? 'danger' : 'success', onClick: () => goTab('backups') }));
  return jsxs('div', {
    className: 'hs-stack',
    children: [
      jsx(DcCard, { dcs: data.dcs }),
      jsx(Card, {
        title: 'Infrastructure',
        sub: 'GPO health and backup age',
        children: jsxs('div', {
          className: 'hs-grid2 hs-even',
          children: [
            jsxs('div', { children: [jsx('div', { className: 'hs-label', children: 'GPO health' }), gpoData.length ? jsx(Donut, { data: gpoData, center: String(total), title: 'GPO health' }) : jsx('div', { className: 'hs-muted', children: 'No GPO data' })] }),
            jsxs('div', { children: [jsx('div', { className: 'hs-label', children: 'Last system-state backup age' }), backups.length ? jsx(BarList, { data: backups, title: 'Backup age per server' }) : jsx('div', { className: 'hs-muted', children: 'No backup data' })] }),
          ],
        }),
      }),
    ],
  });
}

function TrendsCard({ history }) {
  return jsx(Card, {
    title: 'Trends',
    sub: 'last 30 days of inventory runs',
    children: jsx(Pending, {
      q: history,
      label: 'Loading history…',
      children: (d) => {
        const rows = list(d.items)
          .map((r) => r.summary || {})
          .filter((s) => s.total !== undefined);
        if (rows.length < 2) return jsx('div', { className: 'hs-muted', children: 'Collecting history: trends appear after a few inventory runs' });
        const onlinePct = rows.map((s) => (s.total > 0 ? (100 * s.online) / s.total : NaN));
        const patchPcts = rows.map((s) => (s.online > 0 ? (100 * (s.patch_compliant || 0)) / s.online : NaN));
        const reboots = rows.map((s) => num0(s.pending_reboot));
        const last = (arr, f) => (Number.isFinite(arr[arr.length - 1]) ? f(arr[arr.length - 1]) : '—');
        return jsxs('div', {
          className: 'hs-grid3',
          children: [
            jsxs('div', { children: [jsx('div', { className: 'hs-label', children: 'Online' }), jsx(Sparkline, { points: onlinePct, label: 'Computers online', valueText: last(onlinePct, (v) => `${Math.round(v)}%`) })] }),
            jsxs('div', { children: [jsx('div', { className: 'hs-label', children: 'Patch compliance' }), jsx(Sparkline, { points: patchPcts, label: 'Patch compliance', valueText: last(patchPcts, (v) => `${Math.round(v)}%`) })] }),
            jsxs('div', { children: [jsx('div', { className: 'hs-label', children: 'Pending reboots' }), jsx(Sparkline, { points: reboots, label: 'Pending reboots', valueText: String(reboots[reboots.length - 1]) })] }),
          ],
        });
      },
    }),
  });
}

function MonitoringEnableDialog({ seq }) {
  const [deliver, setDeliver] = useState('origin');
  const [mode, setMode] = useState('watchdog');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const submit = async () => {
    setBusy(true);
    setError(null);
    const r = await runWrite(op('monitoring_enable', { deliver: deliver.trim(), mode }), {
      confirmed: true,
      title: 'Enable monitoring',
      confirmLabel: 'Enable monitoring',
      doneMessage: 'Scheduled monitoring enabled',
    });
    if (r.state === 'error') {
      setBusy(false);
      setError(r.error);
    } else if (r.state === 'done') {
      closeDialog(seq);
    }
  };
  return jsx(Modal, {
    seq,
    title: 'Enable monitoring',
    tier: 'W',
    opName: 'monitoring_enable',
    footer: [
      jsx(Btn, { onClick: () => closeDialog(seq), disabled: busy, children: 'Cancel' }, 'cancel'),
      jsx(Btn, { kind: 'primary', onClick: submit, disabled: busy || !deliver.trim(), children: busy ? 'Working…' : 'Enable' }, 'ok'),
    ],
    children: jsxs('div', {
      className: 'hs-stack',
      children: [
        jsx(Field, { label: 'Deliver alerts to', children: jsx(TextInput, { value: deliver, onChange: setDeliver, mono: true, autoFocus: true, placeholder: 'origin, local, telegram' }) }),
        jsx(Field, { label: 'Mode', children: jsx(Seg, { value: mode, options: [['watchdog', 'Watchdog'], ['agent', 'Agent']], onChange: setMode }) }),
        jsx('p', { className: 'hs-muted hs-small hs-p', children: mode === 'agent' ? 'Hermes triages findings before delivering them.' : 'Findings are delivered directly; no agent run when nothing is wrong.' }),
        error ? jsx(ErrorBox, { error }) : null,
      ],
    }),
  });
}

function disableMonitoring() {
  return runWrite(op('monitoring_disable', {}), {
    title: 'Disable monitoring',
    body: 'Stop the scheduled monitoring job? Open alerts stay recorded.',
    confirmLabel: 'Disable monitoring',
    doneMessage: 'Scheduled monitoring disabled',
  });
}

function MonitoringCard({ monitoring, cardRef }) {
  const m = monitoring.res && monitoring.res.ok ? (monitoring.res.data || {}) : null;
  const alerts = m ? list(m.open_alerts) : [];
  return jsx('div', {
    ref: cardRef,
    children: jsx(Card, {
      title: 'Monitoring',
      sub: 'scheduled checks',
      right: m
        ? m.enabled
          ? jsx(Btn, { small: true, onClick: disableMonitoring, children: 'Disable' })
          : jsx(Btn, { small: true, kind: 'primary', onClick: () => openDialog(MonitoringEnableDialog, {}), children: 'Enable' })
        : null,
      children: jsx(Pending, {
        q: monitoring,
        label: 'Loading monitoring status…',
        children: () =>
          jsxs('div', {
            className: 'hs-stack',
            children: [
              jsxs('div', {
                className: 'hs-actions',
                children: [
                  jsx(Badge, { tone: m.enabled ? 'green' : null, children: m.enabled ? 'enabled' : 'disabled' }),
                  jsx('span', { className: 'hs-muted hs-small', children: `Interval: ${m.interval || '—'}` }),
                  jsx('span', { className: 'hs-muted hs-small', children: `Deliver to: ${m.deliver || '—'}` }),
                  jsx('span', { className: 'hs-muted hs-small', children: `Last run: ${m.last_run ? ago(m.last_run) : 'never'}` }),
                ],
              }),
              m.error ? jsx(Callout, { tone: 'yellow', icon: '⚠', children: m.error }) : null,
              jsx(Table, {
                head: ['Rule', 'Host', 'Message', 'First seen'],
                children: alerts.length
                  ? alerts.slice(0, 8).map((a) =>
                      jsxs('tr', {
                        children: [
                          jsx('td', { className: 'hs-mono', children: a.rule }),
                          jsx('td', { children: a.host }),
                          jsx('td', { children: a.message }),
                          jsx('td', { className: 'hs-muted hs-nowrap', children: ago(a.first_seen) }),
                        ],
                      }, a.fingerprint || `${a.rule}-${a.host}`),
                    )
                  : jsx(EmptyRow, { cols: 4, text: 'No open alerts' }),
              }),
              alerts.length > 8 ? jsx('div', { className: 'hs-muted hs-small', children: `${alerts.length - 8} more not shown` }) : null,
            ],
          }),
      }),
    }),
  });
}

const REQUIRED_SERVICES = ['NTDS', 'DNS', 'Netlogon', 'KDC', 'W32Time'];

function ServicesCell({ services }) {
  const svc = services || {};
  const bad = REQUIRED_SERVICES.filter((n) => svc[n] && svc[n] !== 'Running' && svc[n] !== 'Missing');
  if (!bad.length) {
    return jsxs('span', { children: [REQUIRED_SERVICES.filter((n) => svc[n] === 'Running').join(' '), ' ', jsx(Badge, { tone: 'green', children: 'ok' })] });
  }
  return jsx('span', { className: 'hs-actions', children: bad.map((n) => jsx(Badge, { tone: 'red', children: `${n} ${svc[n]}` }, n)) });
}

function DcCard({ dcs }) {
  const items = list(dcs && dcs.items);
  const errors = list(dcs && dcs.errors);
  return jsx(Card, {
    title: 'Domain controllers',
    sub: 'replication · services · time',
    children: jsx(Table, {
      head: ['', 'DC', 'FSMO', 'Replication', 'Services', 'Skew', 'Uptime'],
      children: [
        ...items.map((d) => {
          const rep = d.replication || {};
          const failing = (rep.failures || 0) > 0;
          return jsxs('tr', {
            children: [
              jsx('td', { children: jsx(Dot, { tone: toneOf(d.status) }) }),
              jsxs('td', { children: [jsx('b', { children: d.name }), d.site ? jsx('div', { className: 'hs-muted hs-tiny', children: d.site }) : null] }),
              jsx('td', { className: 'hs-muted', children: list(d.roles).map((r) => ROLE_SHORT[r] || r).join(', ') || '—' }),
              jsx('td', {
                className: failing ? 'hs-text-yellow' : undefined,
                children: d.reachable === false ? 'unreachable' : `${plural(rep.failures || 0, 'failure')} · last ok ${ago(rep.last_success)}`,
              }),
              jsx('td', { children: d.reachable === false ? jsx(Badge, { tone: 'red', children: 'unreachable' }) : jsx(ServicesCell, { services: d.services }) }),
              jsx('td', { className: 'hs-mono', children: skewText(d.time_skew_seconds) }),
              jsx('td', { className: 'hs-muted', children: ageText(d.uptime_hours) }),
            ],
          }, d.name);
        }),
        ...errors.map((e) =>
          jsxs('tr', {
            children: [
              jsx('td', { children: jsx(Dot, { tone: 'bad' }) }),
              jsx('td', { children: jsx('b', { children: shortHost(e.host) }) }),
              jsx('td', { colSpan: 5, className: 'hs-text-red', children: e.message }),
            ],
          }, `err-${e.host}`),
        ),
        !items.length && !errors.length ? jsx(EmptyRow, { cols: 7, text: 'No domain controller data' }, 'empty') : null,
      ],
    }),
  });
}

function RecentChanges({ rows }) {
  const items = list(rows).slice(0, 6);
  return jsx(Card, {
    title: 'Recent changes',
    right: TABS.some((t) => t.key === 'audit')
      ? jsx('button', { type: 'button', className: 'hs-ghost', onClick: () => goTab('audit'), children: 'View all →' })
      : null,
    children: jsx(Table, {
      children: items.length
        ? items.map((a) =>
            jsxs('tr', {
              children: [
                jsx('td', { className: 'hs-mono hs-muted hs-nowrap', children: fmtTime(a.ts) }),
                jsx('td', { children: jsx(TierTag, { tier: a.tier }) }),
                jsxs('td', { children: [jsx('span', { className: 'hs-mono', children: a.tool }), jsx('div', { className: 'hs-muted hs-tiny', children: a.target })] }),
                jsx('td', { children: jsx(AuditDecision, { row: a }) }),
              ],
            }, a.id),
          )
        : jsx(EmptyRow, { cols: 4, text: 'No changes recorded yet' }),
    }),
  });
}

function OverviewTab() {
  const ov = useOverview(true);
  const fleet = useFleet(true);
  const history = useFleetHistory(30, true);
  const monitoring = useMonitoring(true);
  const alertsRef = useRef(null);
  return jsx(Pending, {
    q: ov,
    label: 'Loading the domain overview…',
    children: (d) =>
      jsxs('div', {
        className: 'hs-stack',
        children: [
          jsx(SectionErrors, { errors: d.errors }),
          jsx(AttentionCard, { data: d, fleet, monitoring, alertsRef }),
          jsx(OverviewKpis, { data: d, fleet, monitoring, alertsRef }),
          jsx(FleetCharts, { fleet, diskPct: diskThreshold(monitoring) }),
          jsxs('div', { className: 'hs-grid2 hs-even', children: [jsx(IdentityCard, { data: d }), jsx(SecurityCard, { fleet })] }),
          jsx(InfrastructureCard, { data: d }),
          jsx(TrendsCard, { history }),
          jsx(MonitoringCard, { monitoring, cardRef: alertsRef }),
          jsx(RecentChanges, { rows: d.audit }),
        ],
      }),
  });
}
