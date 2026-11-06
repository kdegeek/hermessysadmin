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

function OverviewKpis({ data }) {
  const k = data.kpis || {};
  const dom = data.domain || {};
  const staleDays = dom.stale_days || 90;
  const expDays = dom.expiring_days || 7;
  const oldest = k.oldest_system_state;
  return jsxs('div', {
    className: 'hs-kpis',
    children: [
      jsx(Kpi, { value: num(k.users), label: 'Users', sub: `${num(k.users_disabled)} disabled`, onClick: () => goTab('users', { users: { status: 'any' } }) }),
      jsx(Kpi, {
        value: num(k.users_locked),
        label: 'Locked out',
        sub: k.users_locked ? 'unlock from the Users tab' : 'none locked',
        tone: k.users_locked ? 'red' : null,
        onClick: () => goTab('users', { users: { status: 'locked' } }),
      }),
      jsx(Kpi, {
        value: num(k.passwords_expiring),
        label: `Passwords expiring ≤${expDays} d`,
        sub: k.passwords_expiring ? 'review in Users' : 'none soon',
        tone: k.passwords_expiring ? 'yellow' : null,
        onClick: () => goTab('users', { users: { expiring: true } }),
      }),
      jsx(Kpi, { value: num(k.computers), label: 'Computers', sub: `${num(k.computers_stale)} stale >${staleDays} d`, onClick: () => goTab('rdp', { rdpView: 'hosts' }) }),
      jsx(Kpi, {
        value: num(k.gpos),
        label: 'GPOs',
        sub: `${num(k.gpos_needing_attention)} need attention`,
        tone: k.gpos_needing_attention ? 'yellow' : null,
        onClick: () => goTab('gpo'),
      }),
      jsx(Kpi, { value: num(k.rdp_sessions), label: 'RDP sessions', sub: `${num(k.rdp_active)} active`, onClick: () => goTab('rdp', { rdpView: 'sessions' }) }),
      jsx(Kpi, {
        value: oldest ? ageText(oldest.age_hours) : '—',
        label: 'Oldest system-state backup',
        sub: oldest ? oldest.host : 'no data',
        tone: k.backups_bad ? 'red' : null,
        onClick: () => goTab('backups'),
      }),
    ],
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
  return jsx(Pending, {
    q: ov,
    label: 'Loading the domain overview…',
    children: (d) =>
      jsxs('div', {
        children: [
          jsx(SectionErrors, { errors: d.errors }),
          jsx(OverviewKpis, { data: d }),
          jsxs('div', { className: 'hs-grid2', children: [jsx(DcCard, { dcs: d.dcs }), jsx(RecentChanges, { rows: d.audit })] }),
        ],
      }),
  });
}

