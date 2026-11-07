// ============================================================================
// §12 TAB: REMOTE ACCESS (sessions, hosts, Connect)
// ============================================================================
async function connectRdp(hostName) {
  const r = await api.read(op('rdp_connect_file', { host: hostName }));
  if (!r.ok) {
    openDialog(ErrorDialog, { title: `Connect to ${shortHost(hostName)}`, error: r.error });
    return;
  }
  const f = r.data;
  let opened = false;
  try {
    opened = !!(f.uri && (await CTX.os.openExternal(f.uri)));
  } catch (_) {
    opened = false;
  }
  if (opened) {
    host.notify({ kind: 'info', message: `Opening Remote Desktop to ${shortHost(f.host)}…` });
    return;
  }
  const saved = await saveText(f.filename || `${safeName(shortHost(hostName))}.rdp`, String(f.content || ''));
  host.notify({ kind: saved.ok ? 'info' : 'error', message: savedMessage(`${f.filename || 'Connection file'}`, saved) });
}

function warnDone(data) {
  if (data && data.warning) host.notify({ kind: 'warning', message: String(data.warning) });
}

function disconnectSession(s) {
  return runWrite(op('rdp_session_disconnect', { host: s.host, session_id: s.id }), {
    title: 'Disconnect session',
    body: `Disconnect ${s.user} on ${shortHost(s.host)}? Their programs keep running and they can reconnect.`,
    confirmLabel: 'Disconnect',
    doneMessage: `${s.user} disconnected from ${shortHost(s.host)}`,
  });
}

function UnreachableCallout({ errors, what }) {
  const errs = list(errors);
  if (!errs.length) return null;
  return jsx(Callout, {
    tone: 'yellow',
    icon: '⚠',
    children: jsxs('div', {
      className: 'hs-row',
      children: [
        jsx('span', { children: `${plural(errs.length, 'server')} could not be reached for ${what}: ${errs.slice(0, 3).map((e) => shortHost(e.host)).join(', ')}${errs.length > 3 ? '…' : ''}` }),
        jsx('span', { className: 'hs-grow' }),
        jsx(Btn, {
          small: true,
          kind: 'ghost',
          onClick: () =>
            openDialog(InfoDialog, {
              title: 'Unreachable servers',
              wide: true,
              children: jsx(Table, {
                head: ['Server', 'Error'],
                children: errs.map((e, i) => jsxs('tr', { children: [jsx('td', { className: 'hs-mono', children: e.host }), jsx('td', { className: 'hs-muted', children: e.message })] }, i)),
              }),
            }),
          children: 'Details',
        }),
      ],
    }),
  });
}

function SessionsView() {
  const [text, setText] = useState('');
  const [onlyDisc, setOnlyDisc] = useState(false);
  const [onlyIdle, setOnlyIdle] = useState(false);
  const q = useOp(op('rdp_sessions', {}), { refetchInterval: POLL.sessions });
  return jsx(Pending, {
    q,
    label: 'Scanning servers for sessions…',
    children: (d) => {
      const t = text.trim().toLowerCase();
      const rows = list(d.items).filter((s) => {
        if (onlyDisc && s.state !== 'disconnected') return false;
        if (onlyIdle && !(s.idle_minutes > 1440)) return false;
        return !t || String(s.user).toLowerCase().includes(t) || String(s.host).toLowerCase().includes(t);
      });
      const sum = d.summary || {};
      return jsxs('div', {
        className: 'hs-stack',
        children: [
          jsxs('div', {
            className: 'hs-toolbar',
            children: [
              jsx(SearchBox, { value: text, onChange: setText, placeholder: 'Filter by user or server…' }),
              jsx(Chip, { on: onlyDisc, onClick: () => setOnlyDisc(!onlyDisc), children: 'Disconnected' }),
              jsx(Chip, { on: onlyIdle, onClick: () => setOnlyIdle(!onlyIdle), children: 'Idle >1 d' }),
              jsx('span', { className: 'hs-grow' }),
              jsx('span', { className: 'hs-muted hs-small', children: `${plural(Number(sum.sessions) || 0, 'session')} · ${num(sum.active)} active · ${num(sum.disconnected)} disconnected · ${num(sum.reachable)}/${num(sum.hosts)} servers reachable` }),
            ],
          }),
          jsx(UnreachableCallout, { errors: d.errors, what: 'sessions' }),
          jsx(Card, {
            children: jsx(Table, {
              head: ['User', 'Server', 'State', 'Idle', 'Logon', ''],
              children: rows.length
                ? rows.map((s) =>
                    jsxs('tr', {
                      children: [
                        jsx('td', { children: jsx('b', { children: s.user }) }),
                        jsx('td', { className: 'hs-mono', children: shortHost(s.host) }),
                        jsxs('td', {
                          children: [
                            s.state === 'active' ? jsx(Badge, { tone: 'green', children: 'active' }) : jsx(Badge, { tone: 'yellow', children: 'disconnected' }),
                            s.state === 'disconnected' && s.idle_minutes > 1440 ? ' ' : null,
                            s.state === 'disconnected' && s.idle_minutes > 1440
                              ? jsx(Badge, { tone: 'red', title: 'Disconnected for over a day: may hold stale credentials that lock the account after a password change', children: 'stale >1 d' })
                              : null,
                          ],
                        }),
                        jsx('td', { className: 'hs-muted', title: s.idle || undefined, children: idleText(s.idle_minutes, s.idle) }),
                        jsx('td', { className: 'hs-muted', children: fmtDate(s.logon) }),
                        jsx('td', {
                          className: 'hs-nowrap',
                          children: jsxs('div', {
                            className: 'hs-actions',
                            children: [
                              jsx(Btn, { small: true, kind: 'ghost', onClick: () => openDialog(MessageDialog, { session: s }), children: 'Message' }),
                              s.state === 'active' ? jsx(Btn, { small: true, kind: 'ghost', onClick: () => disconnectSession(s), children: 'Disconnect' }) : null,
                              jsx(Btn, { small: true, kind: 'danger', onClick: () => logoffSession(s), children: 'Log off' }),
                              jsx(Btn, { small: true, onClick: () => connectRdp(s.host), children: 'Connect' }),
                            ],
                          }),
                        }),
                      ],
                    }, `${s.host}-${s.id}`),
                  )
                : jsx(EmptyRow, { cols: 6, text: 'No sessions match' }),
            }),
          }),
        ],
      });
    },
  });
}

function setRdpEnabled(h, enabled) {
  return runWrite(op('rdp_set_enabled', { hosts: [h.host], enabled }), {
    title: enabled ? 'Allow Remote Desktop' : 'Turn off Remote Desktop',
    body: enabled
      ? `Allow Remote Desktop connections to ${shortHost(h.host)} and open the firewall rule?`
      : `Turn off Remote Desktop on ${shortHost(h.host)}? Existing sessions stay connected; new connections are refused.`,
    confirmLabel: enabled ? 'Allow' : 'Turn off',
    destructive: !enabled,
    doneMessage: `Remote Desktop ${enabled ? 'allowed' : 'turned off'} on ${shortHost(h.host)}`,
  });
}

function setRdpNla(h, required) {
  return runWrite(op('rdp_set_nla', { hosts: [h.host], required }), {
    title: required ? 'Require NLA' : 'Stop requiring NLA',
    body: required
      ? `Require Network Level Authentication on ${shortHost(h.host)}?`
      : `Stop requiring Network Level Authentication on ${shortHost(h.host)}? Unauthenticated clients will reach the logon screen.`,
    confirmLabel: 'Apply',
    destructive: !required,
    doneMessage: `NLA ${required ? 'required' : 'no longer required'} on ${shortHost(h.host)}`,
  });
}

function HostsView() {
  const q = useOp(op('rdp_host_status', {}), { refetchInterval: POLL.list });
  const dcs = useOp(op('ad_dc_list', {}), { staleTime: 300000 });
  const dcNames = dcs.res && dcs.res.ok ? list(dcs.res.data.items).map((d) => d.hostname || d.name) : [];
  return jsx(Pending, {
    q,
    label: 'Checking Remote Desktop settings on servers…',
    children: (d) => {
      const sum = d.summary || {};
      return jsxs('div', {
        className: 'hs-stack',
        children: [
          jsx('div', {
            className: 'hs-toolbar',
            children: jsx('span', { className: 'hs-muted hs-small', children: `${num(sum.hosts)} servers · ${num(sum.enabled)} allow RDP · ${num(sum.nla_off)} without NLA · ${num(sum.unreachable)} unreachable` }),
          }),
          jsx(UnreachableCallout, { errors: d.errors, what: 'RDP settings' }),
          jsx(Card, {
            children: jsx(Table, {
              head: ['Server', 'RDP', 'NLA', 'Firewall', 'Remote Desktop Users', ''],
              children: list(d.items).length
                ? list(d.items).map((h) => {
                    const isDc = dcNames.some((n) => sameHost(n, h.host));
                    return jsxs('tr', {
                      children: [
                        jsxs('td', {
                          children: [
                            jsx('b', { className: 'hs-mono', children: shortHost(h.host) }),
                            isDc ? ' ' : null,
                            isDc ? jsx(Badge, { tone: 'accent', title: 'Domain controller: RDP changes are high-risk', children: 'DC' }) : null,
                            jsx('div', { className: 'hs-muted hs-tiny', children: h.os || '' }),
                            list(h.warnings).length ? jsx('div', { className: 'hs-text-yellow hs-tiny', children: list(h.warnings).join(' · ') }) : null,
                          ],
                        }),
                        jsx('td', { children: jsx(Toggle, { on: h.enabled, title: h.enabled ? 'Remote Desktop allowed' : 'Remote Desktop off', onChange: (v) => setRdpEnabled(h, v) }) }),
                        jsx('td', { children: jsx(Toggle, { on: h.nla, title: h.nla ? 'NLA required' : 'NLA not required', onChange: (v) => setRdpNla(h, v) }) }),
                        jsx('td', { children: h.firewall_open ? jsx(Badge, { tone: 'green', children: `open :${h.port}` }) : jsx(Badge, { tone: h.enabled ? 'red' : undefined, children: 'closed' }) }),
                        jsx('td', {
                          children: h.rdp_users === null || h.rdp_users === undefined
                            ? jsx('span', { className: 'hs-muted', children: 'unknown' })
                            : jsxs('div', {
                                className: 'hs-actions',
                                children: [
                                  ...list(h.rdp_users).map((m) =>
                                    jsxs(Badge, {
                                      children: [
                                        m,
                                        jsx('button', {
                                          type: 'button',
                                          className: 'hs-ghost hs-x',
                                          title: `Remove ${m}`,
                                          onClick: () =>
                                            runWrite(op('rdp_users_remove', { host: h.host, members: [m] }), {
                                              title: 'Remove from Remote Desktop Users',
                                              body: `Remove ${m} from Remote Desktop Users on ${shortHost(h.host)}?`,
                                              confirmLabel: 'Remove',
                                              onDone: warnDone,
                                              doneMessage: `${m} removed from Remote Desktop Users on ${shortHost(h.host)}`,
                                            }),
                                          children: '✕',
                                        }),
                                      ],
                                    }, m),
                                  ),
                                  jsx(Btn, { small: true, kind: 'ghost', onClick: () => openDialog(RdpUsersAddDialog, { hostName: h.host }), children: '+ Add' }, '+add'),
                                ],
                              }),
                        }),
                        jsx('td', { children: jsx(Btn, { small: true, disabled: !h.enabled, onClick: () => connectRdp(h.host), children: 'Connect' }) }),
                      ],
                    }, h.host);
                  })
                : jsx(EmptyRow, { cols: 6, text: 'No servers found' }),
            }),
          }),
        ],
      });
    },
  });
}

function RdpTab() {
  const view = useValue($rdpView);
  return jsxs('div', {
    className: 'hs-stack',
    children: [
      jsx('div', { className: 'hs-toolbar', children: jsx(Seg, { value: view, options: [['sessions', 'Sessions'], ['hosts', 'Hosts']], onChange: (v) => $rdpView.set(v) }) }),
      view === 'hosts' ? jsx(HostsView, {}) : jsx(SessionsView, {}),
    ],
  });
}

function MessageDialog({ seq, session }) {
  const [text, setText] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const submit = async () => {
    setBusy(true);
    setError(null);
    const r = await runWrite(op('rdp_session_message', { host: session.host, session_id: session.id, message: text.trim(), seconds: 60 }), {
      confirmed: true,
      title: 'Send message',
      doneMessage: `Message sent to ${session.user} on ${shortHost(session.host)}`,
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
    title: `Message ${session.user} on ${shortHost(session.host)}`,
    tier: 'W',
    opName: 'rdp_session_message',
    footer: [
      jsx(Btn, { onClick: () => closeDialog(seq), disabled: busy, children: 'Cancel' }, 'cancel'),
      jsx(Btn, { kind: 'primary', onClick: submit, disabled: busy || !text.trim(), children: 'Send' }, 'ok'),
    ],
    children: jsxs('div', {
      className: 'hs-stack',
      children: [
        jsx(TextArea, { value: text, onChange: setText, placeholder: 'The server restarts at 18:00. Please save your work and sign out.' }),
        jsx('div', { className: 'hs-muted hs-small', children: 'Shown in a pop-up in their session for 60 seconds.' }),
        error ? jsx(ErrorBox, { error }) : null,
      ],
    }),
  });
}

function RdpUsersAddDialog({ seq, hostName }) {
  const [members, setMembers] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const names = splitList(members);
  const submit = async () => {
    setBusy(true);
    setError(null);
    const r = await runWrite(op('rdp_users_add', { host: hostName, members: names }), {
      confirmed: true,
      onDone: warnDone,
      title: 'Add to Remote Desktop Users',
      doneMessage: `${names.join(', ')} added to Remote Desktop Users on ${shortHost(hostName)}`,
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
    title: `Remote Desktop Users · ${shortHost(hostName)}`,
    tier: 'W',
    opName: 'rdp_users_add',
    footer: [
      jsx(Btn, { onClick: () => closeDialog(seq), disabled: busy, children: 'Cancel' }, 'cancel'),
      jsx(Btn, { kind: 'primary', onClick: submit, disabled: busy || !names.length, children: 'Add' }, 'ok'),
    ],
    children: jsxs('div', {
      className: 'hs-stack',
      children: [
        jsx(Field, { label: 'Users or groups (sAMAccountName or DOMAIN\\name, comma separated)', children: jsx(TextInput, { value: members, onChange: setMembers, autoFocus: true, placeholder: 'CORP\\Helpdesk' }) }),
        error ? jsx(ErrorBox, { error }) : null,
      ],
    }),
  });
}

