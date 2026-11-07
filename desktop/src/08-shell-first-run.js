// ============================================================================
// §8 SHELL: FIRST-RUN CARD, HEADER, TAB BAR, PAGE, STATUS-BAR ITEM
// ============================================================================
function TestResult({ res }) {
  if (!res.ok) return jsx(ErrorBox, { error: res.error });
  const d = res.data || {};
  const mods = d.modules || {};
  const mark = (name) => `${name} ${mods[name] ? '✓' : '✗'}`;
  return jsxs('div', {
    className: 'hs-stack',
    children: [
      jsx(Callout, {
        tone: 'accent',
        icon: Ico('pass'),
        children: jsxs('div', {
          children: [
            jsxs('div', { children: [d.transport === 'local' ? 'PowerShell on ' : 'Connected to ', jsx('b', { children: d.hostname || '—' }), ` · ${d.os || 'Windows'} · domain ${d.domain || '—'}`] }),
            jsx('div', { className: 'hs-muted', children: identityLine(d) }),
            jsx('div', { children: [mark('ActiveDirectory'), mark('GroupPolicy'), mark('WindowsServerBackup')].join(' · ') }),
            jsx('div', {
              className: 'hs-muted',
              children: `${d.is_domain_controller ? 'Domain controller' : 'Not a domain controller'} · PowerShell ${d.ps_version || '—'}`,
            }),
            list(d.privileged_memberships).length
              ? jsx('div', { className: 'hs-muted', children: `Privileged memberships: ${list(d.privileged_memberships).join(', ')}` })
              : null,
          ],
        }),
      }),
      ...list(d.warnings).map((w, i) => jsx(Callout, { tone: 'yellow', icon: Ico('warning'), children: w }, `w${i}`)),
    ],
  });
}

function SetupCard({ health }) {
  const [busy, setBusy] = useState(false);
  const [res, setRes] = useState(null);
  const test = async () => {
    setBusy(true);
    const r = await api.testConnection();
    setBusy(false);
    setRes(r);
    queryClient.invalidateQueries({ queryKey: KEY.health });
  };
  return jsxs('div', {
    className: 'hs-empty',
    children: [
      jsx('div', { className: 'hs-big', children: Ico('organization') }),
      jsx('h2', { children: 'Connect to Active Directory' }),
      jsx('p', {
        className: 'hs-muted',
        children: 'On a domain-joined Windows machine Hermes runs PowerShell locally (transport: local), as the Hermes user or as an account you choose. Elsewhere it reaches the domain through one WinRM jump host, which must be a domain controller. Passwords are stored in Hermes secrets.',
      }),
      jsxs('div', {
        className: 'hs-form',
        children: [
          jsx('div', { className: 'hs-label', children: 'Set these in the plugin settings' }),
          jsxs('ul', {
            className: 'hs-checklist',
            children: [
              jsx('li', { children: 'Transport: auto (local on a domain-joined Windows machine, else WinRM), local or winrm' }),
              jsx('li', { children: 'Local: Run as the Hermes user, or as the account below (its network logons use that account)' }),
              jsx('li', { children: 'WinRM: jump host, the domain controller FQDN, e.g. dc01.corp.example.local' }),
              jsx('li', { children: 'WinRM port and HTTPS: 5986 with HTTPS, or 5985 (NTLM/Kerberos still encrypts)' }),
              jsx('li', { children: 'Authentication: NTLM or Kerberos' }),
              jsx('li', { children: 'Username, e.g. CORP\\svc-hermes, and its password (kept in Hermes secrets)' }),
            ],
          }),
          health && (health.host || health.transport === 'local') ? jsx('div', { className: 'hs-muted hs-small', children: `Configured: ${connectionLabel(health)}` }) : null,
          jsx('div', {
            className: 'hs-muted hs-small',
            children: 'Settings → Plugins → Sysadmin · Active Directory. Save, then press Test connection.',
          }),
          jsxs('div', {
            className: 'hs-end',
            children: [
              jsx(Btn, { onClick: () => host.navigate(SETTINGS_HREF), children: 'Open plugin settings' }),
              jsx(Btn, { kind: 'primary', onClick: test, disabled: busy, children: busy ? 'Testing…' : 'Test connection' }),
            ],
          }),
          res ? jsx(TestResult, { res }) : null,
        ],
      }),
    ],
  });
}

function UpdatedAgo({ at, refreshing }) {
  useTick(10000);
  const text = at ? `updated ${ago(at)}` : 'loading…';
  return jsx('span', { className: 'hs-muted hs-small', children: refreshing && at ? `${text} · refreshing…` : text });
}

function Header({ health, overview }) {
  const [busy, setBusy] = useState(false);
  const ov = overview.res && overview.res.ok ? overview.res.data : null;
  const domain = ov && ov.domain ? ov.domain.domain : '';
  const refresh = async () => {
    setBusy(true);
    await api.refresh();
    invalidateAll();
    setBusy(false);
  };
  return jsxs('div', {
    className: 'hs-head',
    children: [
      jsx('h1', { children: 'Active Directory' }),
      jsx('span', { className: 'hs-domain', children: `${domain || 'domain'} · ${connectionLabel(health)}` }),
      jsx('span', { className: 'hs-grow' }),
      jsx(Badge, { tone: 'accent', children: `mode: ${health.mode}` }),
      health.escape_enabled ? jsx(Badge, { tone: 'red', children: 'PowerShell escape hatch on' }) : null,
      jsx(UpdatedAgo, { at: overview.updatedAt, refreshing: overview.refreshing }),
      jsx(Btn, { small: true, onClick: refresh, disabled: busy, children: busy ? 'Refreshing…' : [Ico('refresh', 'i'), 'Refresh'] }),
    ],
  });
}

function TabBar({ kpis }) {
  const tab = useValue($tab);
  return jsx('div', {
    className: 'hs-tabs',
    children: TABS.map((t) => {
      const n = t.badge(kpis || {});
      return jsxs('button', {
        type: 'button',
        className: `hs-tab${tab === t.key ? ' on' : ''}`,
        onClick: () => goTab(t.key),
        children: [t.label, n ? jsx('span', { className: 'hs-n', children: n }) : null],
      }, t.key);
    }),
  });
}

function BackendDown({ error, onRetry }) {
  return jsx('div', {
    className: 'hs-empty',
    children: jsx(ErrorState, {
      title: "The hermes-sysadmin backend didn't answer",
      description: error ? `${error.type}: ${error.message}` : undefined,
      children: jsxs('div', {
        className: 'hs-stack',
        children: [
          error && error.hint ? jsx('div', { className: 'hs-muted hs-small', children: error.hint }) : null,
          jsx('div', { className: 'hs-end', style: { justifyContent: 'center' }, children: jsx(Btn, { onClick: onRetry, children: 'Retry' }) }),
        ],
      }),
    }),
  });
}

function Page() {
  const tab = useValue($tab);
  const health = useHealth();
  const h = health.res && health.res.ok ? health.res.data : null;
  const configured = !!(h && h.configured);
  const overview = useOverview(configured);
  const def = TABS.find((t) => t.key === tab) || TABS[0];
  let body;
  if (!health.res) {
    body = jsx(Spinner, { label: 'Checking the connection…' });
  } else if (!health.res.ok) {
    body = jsx(BackendDown, { error: health.res.error, onRetry: () => health.refetch() });
  } else if (!configured) {
    body = jsx(SetupCard, { health: h });
  } else {
    const kpis = overview.res && overview.res.ok ? overview.res.data.kpis : {};
    body = jsxs('div', {
      children: [jsx(Header, { health: h, overview }), jsx(TabBar, { kpis }), def.render()],
    });
  }
  return jsxs('div', {
    className: 'hs-root',
    tabIndex: -1,
    onKeyDown: (e) => {
      if (e.key === 'Escape' && !$dialog.get()) $drawer.set(null);
    },
    children: [
      jsx('style', { children: CSS }),
      jsx('div', { className: 'hs-scroll', children: jsx('div', { className: 'hs-page', children: body }) }),
      configured && def.overlay ? def.overlay() : null,
      jsx(DialogHost, {}),
    ],
  });
}

const STATUS_WORD = { ok: '', warn: 'warning', bad: 'DC problem', unconfigured: 'not set up', unknown: 'status unknown' };

function StatusBarItem() {
  const health = useHealth();
  const cached = useApi(KEY.overview, api.overview, { enabled: false });
  const h = health.res && health.res.ok ? health.res.data : null;
  const status = !h ? 'unknown' : h.configured ? h.status || 'unknown' : 'unconfigured';
  const ov = cached.res && cached.res.ok ? cached.res.data : null;
  const parts = [(ov && ov.domain && ov.domain.domain) || (h && h.host) || 'Active Directory'];
  if (STATUS_WORD[status]) parts.push(STATUS_WORD[status]);
  const locked = ov && ov.kpis ? ov.kpis.users_locked : 0;
  if (locked) parts.push(`${locked} locked`);
  return jsxs('button', {
    type: 'button',
    title: 'Active Directory: domain controller health',
    onClick: () => host.navigate(ROUTE),
    style: {
      display: 'inline-flex',
      alignItems: 'center',
      gap: 6,
      padding: '0 6px',
      border: 0,
      background: 'transparent',
      color: 'var(--ui-text-secondary)',
      font: 'inherit',
      fontSize: '11.5px',
      cursor: 'pointer',
    },
    children: [jsx(Dot, { tone: toneOf(status) }), jsx('span', { children: parts.join(' · ') })],
  });
}

