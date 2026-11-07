// ============================================================================
// §10 TAB: USERS (table, filters, drawer, dialogs, Recycle Bin)
// ============================================================================
function passwordInfo(u) {
  if (u.password_never_expires) return { text: 'never expires', warn: false };
  if (u.password_expired) return { text: 'expired', warn: true };
  const days = daysUntil(u.password_expires);
  if (days === null) return { text: '—', warn: false };
  return { text: until(u.password_expires), warn: days <= 7 };
}

function userStatus(u) {
  if (u.locked) return jsx(Badge, { tone: 'red', children: '● locked' });
  if (!u.enabled) return jsx(Badge, { children: 'disabled' });
  return jsx(Badge, { tone: 'green', children: 'active' });
}

function unlockUser(sam) {
  return runWrite(op('ad_user_unlock', { identity: sam }), {
    title: 'Unlock account',
    body: `Unlock ${sam}? The bad-password counter resets. If the lockout source is still active the account will lock again.`,
    confirmLabel: 'Unlock',
    doneMessage: `${sam} unlocked · logged to audit`,
  });
}

// Also used by the Remote Access tab (§12).
function logoffSession(s) {
  return runWrite(op('rdp_session_logoff', { host: s.host, session_id: s.id }), {
    title: 'Log off session',
    body: `Log off ${s.user} from ${shortHost(s.host)} (session ${s.id})? Unsaved work in that session will be lost.`,
    confirmLabel: 'Log off',
    destructive: true,
    doneMessage: `${s.user} logged off ${shortHost(s.host)}`,
  });
}

function UserRow({ u, selected }) {
  const pw = passwordInfo(u);
  return jsxs('tr', {
    className: `click${selected ? ' sel' : ''}`,
    onClick: () => $drawer.set(u.sam),
    children: [
      jsxs('td', { children: [jsx('b', { children: u.display_name || u.name }), u.privileged ? ' ' : null, u.privileged ? jsx(Badge, { tone: 'accent', children: 'privileged' }) : null] }),
      jsx('td', { className: 'hs-mono', children: u.sam }),
      jsx('td', { className: 'hs-muted', title: u.ou, children: ouPath(u.dn) }),
      jsx('td', { children: userStatus(u) }),
      jsx('td', { className: pw.warn ? 'hs-text-yellow' : 'hs-muted', children: pw.text }),
      jsx('td', { className: 'hs-muted', children: ago(u.last_logon) }),
      jsx('td', {
        children: u.locked
          ? jsx(Btn, { small: true, onClick: (e) => { e.stopPropagation(); unlockUser(u.sam); }, children: 'Unlock' })
          : null,
      }),
    ],
  });
}

function UsersTab() {
  const f = useValue($users);
  const focus = useValue($focusSearch);
  const sel = useValue($drawer);
  const [text, setText] = useState(f.query);
  const query = useDebounced(text.trim(), 350);
  useEffect(() => {
    if (query !== $users.get().query) $users.set({ ...$users.get(), query, limit: 200 });
  }, [query]);
  useEffect(() => {
    if (f.query !== query) setText(f.query);
  }, [f.query]);
  const set = (patch) => $users.set({ ...$users.get(), ...patch, limit: 200 });
  const args = { status: f.status, password: f.expiring ? 'expiring' : 'any', privileged: f.privileged, limit: f.limit };
  if (f.query) args.query = f.query;
  if (f.stale) args.stale_days = 90;
  const q = useOp(op('ad_user_list', args), { refetchInterval: POLL.list });
  return jsxs('div', {
    children: [
      jsxs('div', {
        className: 'hs-toolbar',
        children: [
          jsx(SearchBox, { value: text, onChange: setText, placeholder: 'Search name, sAMAccountName, email…', focusSignal: focus }),
          jsx(Chip, { on: f.status === 'locked', onClick: () => set({ status: f.status === 'locked' ? 'any' : 'locked' }), children: 'Locked' }),
          jsx(Chip, { on: f.status === 'disabled', onClick: () => set({ status: f.status === 'disabled' ? 'any' : 'disabled' }), children: 'Disabled' }),
          jsx(Chip, { on: f.stale, onClick: () => set({ stale: !f.stale }), children: 'Stale >90 d' }),
          jsx(Chip, { on: f.expiring, onClick: () => set({ expiring: !f.expiring }), children: 'Expiring ≤7 d' }),
          jsx(Chip, { on: f.privileged, onClick: () => set({ privileged: !f.privileged }), children: 'Privileged' }),
          jsx('span', { className: 'hs-grow' }),
          jsx(Btn, { onClick: () => openDialog(RecycleBinDialog, {}), children: [Ico('trash', 'i'), 'Recycle Bin'] }),
          jsx(Btn, { kind: 'primary', onClick: () => openDialog(NewUserDialog, {}), children: '+ New user' }),
        ],
      }),
      jsx(Pending, {
        q,
        label: 'Reading users…',
        children: (d) => {
          const items = list(d.items);
          const total = typeof d.total === 'number' ? d.total : items.length;
          return jsxs('div', {
            children: [
              jsx(Card, {
                children: jsx(Table, {
                  head: ['Name', 'Account', 'OU', 'Status', 'Password', 'Last logon', ''],
                  children: items.length
                    ? items.map((u) => jsx(UserRow, { u, selected: sel === u.sam }, u.sam))
                    : jsx(EmptyRow, { cols: 7, text: 'No users match these filters' }),
                }),
              }),
              jsxs('div', {
                className: 'hs-toolbar',
                style: { marginTop: 8 },
                children: [
                  jsx('span', { className: 'hs-muted hs-small', children: `Showing ${num(items.length)} of ${num(total)} · filtered on the server` }),
                  items.length < total
                    ? jsx(Btn, { small: true, onClick: () => $users.set({ ...$users.get(), limit: f.limit + 200 }), children: 'Load 200 more' })
                    : null,
                ],
              }),
            ],
          });
        },
      }),
    ],
  });
}

function UserDrawerHost() {
  const sam = useValue($drawer);
  return sam ? jsx(UserDrawer, { sam }, sam) : null;
}

function LockoutCallout({ u, lock, sessions }) {
  const d = lock.res && lock.res.ok ? lock.res.data : null;
  const src = d ? d.likely_source : null;
  const items = sessions.res && sessions.res.ok ? list(sessions.res.data.items) : [];
  const stale = src ? items.find((s) => s.state === 'disconnected' && sameHost(s.host, src)) : null;
  let source;
  if (!lock.res) source = 'Looking for the lockout source…';
  else if (!lock.res.ok) source = `Lockout source lookup failed: ${lock.res.error.message}`;
  else if (src) source = jsxs('span', { children: ['Source: ', jsx('b', { className: 'hs-mono', children: src }), ` (event 4740 on ${shortHost(d.pdc)})`] });
  else source = 'No lockout events found on the PDC emulator in that time range.';
  return jsx(Callout, {
    tone: 'red',
    icon: Ico('lock'),
    children: jsxs('div', {
      children: [
        jsx('b', { children: 'Locked out' }),
        d ? ` · ${plural(list(d.events).length, 'lockout event')} in ${d.hours} h` : '',
        typeof u.bad_password_count === 'number' ? ` · ${u.bad_password_count} bad attempts` : '',
        jsx('div', { children: source }),
        stale
          ? jsx('div', { className: 'hs-muted', children: `A disconnected RDP session on ${shortHost(stale.host)} (idle ${stale.idle}) may be replaying old credentials.` })
          : null,
      ],
    }),
  });
}

function UserActions({ u, isProtected }) {
  const sam = u.sam;
  const title = (tier) => (isProtected ? 'Blocked: protected object' : `${tier}-tier`);
  const toggle = u.enabled
    ? () =>
        runWrite(op('ad_user_disable', { identity: sam }), {
          title: `Disable ${sam}`,
          body: `Disable ${sam}? They can no longer sign in; existing sessions keep running until they sign out.`,
          confirmLabel: 'Disable',
          doneMessage: `${sam} disabled · logged to audit`,
        })
    : () =>
        runWrite(op('ad_user_enable', { identity: sam }), {
          title: `Enable ${sam}`,
          body: `Enable ${sam}? They can sign in again.`,
          confirmLabel: 'Enable',
          doneMessage: `${sam} enabled · logged to audit`,
        });
  return jsxs('div', {
    className: 'hs-actions',
    children: [
      jsx(Btn, { small: true, disabled: isProtected || !u.locked, title: title('W'), onClick: () => unlockUser(sam), children: 'Unlock' }),
      jsx(Btn, { small: true, disabled: isProtected, title: title('W'), onClick: () => openDialog(ResetPasswordDialog, { sam }), children: 'Reset password' }),
      jsx(Btn, { small: true, disabled: isProtected, title: title('W'), onClick: toggle, children: u.enabled ? 'Disable' : 'Enable' }),
      jsx(Btn, { small: true, disabled: isProtected, title: title('W'), onClick: () => openDialog(MoveUserDialog, { sam, ou: u.ou }), children: 'Move…' }),
      jsx(Btn, { small: true, disabled: isProtected, title: title('W'), onClick: () => openDialog(AddToGroupDialog, { sam }), children: 'Add to group…' }),
      jsx(Btn, {
        small: true,
        kind: 'danger',
        disabled: isProtected,
        title: title('H'),
        onClick: () =>
          runWrite(op('ad_user_delete', { identity: sam }), {
            title: 'Delete user',
            confirmLabel: 'Delete user',
            doneMessage: `${sam} deleted · logged to audit`,
            onDone: () => $drawer.set(null),
          }),
        children: 'Delete',
      }),
    ],
  });
}

function UserDrawer({ sam }) {
  const q = useOp(op('ad_user_get', { identity: sam }));
  const guardOp = op('ad_user_disable', { identity: sam });
  const guard = useApi(KEY.decision(guardOp), () => api.decision(guardOp), { staleTime: 60000 });
  const u = q.res && q.res.ok ? q.res.data : null;
  const lock = useOp(op('ad_lockout_source', { identity: sam }), { enabled: !!(u && u.locked) });
  const sessions = useOp(op('rdp_sessions', { user: sam }), { staleTime: 30000 });
  const isProtected = !!(guard.res && guard.res.ok && guard.res.data.action === 'block' && guard.res.data.tier === 'P');
  const name = u ? u.display_name || u.name || sam : sam;
  const groups = u ? list(u.groups) : [];
  const sessionItems = sessions.res && sessions.res.ok ? list(sessions.res.data.items) : [];
  const pw = u ? passwordInfo(u) : null;
  return jsxs('aside', {
    className: 'hs-drawer',
    children: [
      jsxs('div', {
        className: 'hs-dh',
        children: [
          jsx('div', { className: 'hs-avatar', children: initials(name) }),
          jsxs('div', { style: { flex: 1, minWidth: 0 }, children: [jsx('b', { children: name }), jsx('div', { className: 'hs-muted hs-mono', children: (u && u.upn) || sam })] }),
          jsx('button', { type: 'button', className: 'hs-ghost', title: 'Close', onClick: () => $drawer.set(null), children: Ico('close') }),
        ],
      }),
      !u
        ? jsx('div', { className: 'hs-sec', children: jsx(Pending, { q, label: 'Reading the account…', children: () => null }) })
        : jsxs('div', {
            children: [
              isProtected
                ? jsx('div', {
                    className: 'hs-sec',
                    children: jsx(Callout, {
                      tone: 'red',
                      icon: Ico('shield'),
                      children: jsxs('div', { children: [jsx('b', { children: 'Protected object.' }), ' All write actions are blocked by policy for this account.'] }),
                    }),
                  })
                : null,
              u.locked ? jsx('div', { className: 'hs-sec', children: jsx(LockoutCallout, { u, lock, sessions }) }) : null,
              jsxs('div', { className: 'hs-sec', children: [jsx('h4', { children: 'Actions' }), jsx(UserActions, { u, isProtected })] }),
              jsxs('div', {
                className: 'hs-sec',
                children: [
                  jsx('h4', { children: 'Account' }),
                  jsx(KV, {
                    rows: [
                      ['OU', jsx('span', { className: 'hs-mono hs-tiny', children: u.ou || '—' })],
                      ['Enabled', u.enabled ? 'Yes' : 'No'],
                      ['Password expires', u.password_last_set ? `${pw.text} (set ${fmtDay(u.password_last_set)})` : pw.text],
                      ['Last logon', ago(u.last_logon)],
                      ['Email', u.email || '—'],
                      u.title ? ['Title', u.title] : null,
                      u.department ? ['Department', u.department] : null,
                      u.manager ? ['Manager', u.manager] : null,
                      ['Created', fmtDay(u.created)],
                    ],
                  }),
                ],
              }),
              jsxs('div', {
                className: 'hs-sec',
                children: [
                  jsx('h4', { children: `Groups (${groups.length})` }),
                  jsx('div', {
                    className: 'hs-actions',
                    children: groups.length
                      ? groups.map((g) =>
                          jsxs(Badge, {
                            tone: /admins|operators/i.test(g) ? 'accent' : undefined,
                            children: [
                              g,
                              isProtected
                                ? null
                                : jsx('button', {
                                    type: 'button',
                                    className: 'hs-ghost hs-x',
                                    title: `Remove from ${g}`,
                                    onClick: () =>
                                      runWrite(op('ad_group_remove_member', { group: g, members: [sam] }), {
                                        title: 'Remove from group',
                                        body: `Remove ${sam} from ${g}?`,
                                        confirmLabel: 'Remove',
                                        doneMessage: `${sam} removed from ${g}`,
                                      }),
                                    children: Ico('close'),
                                  }),
                            ],
                          }, g),
                        )
                      : jsx('span', { className: 'hs-muted', children: 'None' }),
                  }),
                ],
              }),
              jsxs('div', {
                className: 'hs-sec',
                children: [
                  jsx('h4', { children: 'Remote sessions' }),
                  !sessions.res
                    ? jsx(Spinner, { label: 'Looking for sessions on servers…' })
                    : !sessions.res.ok
                      ? jsx(ErrorBox, { error: sessions.res.error })
                      : sessionItems.length
                        ? jsx('div', {
                            children: sessionItems.map((s) =>
                              jsxs('div', {
                                className: 'hs-row',
                                children: [
                                  jsx(Dot, { tone: s.state === 'active' ? 'good' : 'warn' }),
                                  jsx('span', { className: 'hs-mono', children: shortHost(s.host) }),
                                  jsx('span', { className: 'hs-muted', children: `${s.state} · idle ${s.idle}` }),
                                  jsx('span', { className: 'hs-grow' }),
                                  jsx(Btn, { small: true, onClick: () => logoffSession(s), children: 'Log off' }),
                                ],
                              }, `${s.host}-${s.id}`),
                            ),
                          })
                        : jsx('span', { className: 'hs-muted', children: 'None' }),
                ],
              }),
            ],
          }),
    ],
  });
}

function ResetPasswordDialog({ seq, sam }) {
  const [mode, setMode] = useState('generate');
  const [password, setPassword] = useState('');
  const [mustChange, setMustChange] = useState(true);
  const [unlock, setUnlock] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const submit = async () => {
    const args = { identity: sam, must_change: mustChange, unlock };
    if (mode === 'manual') {
      if (!password) {
        setError({ type: 'InvalidArguments', message: 'Enter a password, or choose Generate.' });
        return;
      }
      args.password = password;
    }
    setBusy(true);
    setError(null);
    const r = await runWrite(op('ad_user_reset_password', args), {
      confirmed: true,
      title: `Reset password · ${sam}`,
      quiet: true,
      onDone: (data) => {
        if (data.password) {
          openDialog(SecretDialog, {
            title: 'Password reset',
            who: data.identity || sam,
            secret: data.password,
            note: `${data.must_change ? 'A change is required at next logon.' : ''}${data.unlocked ? ' The account was unlocked.' : ''}${list(data.warnings).length ? ` Warnings: ${list(data.warnings).join(' ')}` : ''}`,
          });
        } else {
          host.notify({ kind: 'success', message: `Password reset for ${sam} · logged to audit` });
        }
      },
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
    title: `Reset password · ${sam}`,
    tier: 'W',
    opName: 'ad_user_reset_password',
    footer: [
      jsx(Btn, { onClick: () => closeDialog(seq), disabled: busy, children: 'Cancel' }, 'cancel'),
      jsx(Btn, { kind: 'primary', onClick: submit, disabled: busy, children: busy ? 'Resetting…' : 'Reset password' }, 'ok'),
    ],
    children: jsxs('div', {
      className: 'hs-stack',
      children: [
        jsx(Seg, { value: mode, options: [['generate', 'Generate'], ['manual', 'Set manually']], onChange: setMode }),
        mode === 'manual' ? jsx(Field, { label: 'New password', children: jsx(TextInput, { type: 'password', value: password, onChange: setPassword }) }) : null,
        jsx(CheckRow, { checked: mustChange, onChange: setMustChange, label: 'User must change password at next logon' }),
        jsx(CheckRow, { checked: unlock, onChange: setUnlock, label: 'Unlock account if locked' }),
        jsx('p', {
          className: 'hs-muted hs-small hs-p',
          children: 'A 20-character password is generated on the server and shown once. It is never written to the audit log.',
        }),
        error ? jsx(ErrorBox, { error }) : null,
      ],
    }),
  });
}

function MoveUserDialog({ seq, sam, ou }) {
  const [target, setTarget] = useState(ou || '');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const submit = async () => {
    setBusy(true);
    setError(null);
    const r = await runWrite(op('ad_user_move', { identity: sam, target_ou: target.trim() }), {
      confirmed: true,
      title: `Move ${sam}`,
      doneMessage: `${sam} moved to ${shortDn(target)}`,
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
    title: `Move ${sam}`,
    tier: 'W',
    opName: 'ad_user_move',
    footer: [
      jsx(Btn, { onClick: () => closeDialog(seq), disabled: busy, children: 'Cancel' }, 'cancel'),
      jsx(Btn, { kind: 'primary', onClick: submit, disabled: busy || !target.trim() || target.trim() === ou, children: 'Move' }, 'ok'),
    ],
    children: jsxs('div', {
      className: 'hs-stack',
      children: [
        jsx(Field, { label: 'Destination OU (distinguished name)', children: jsx(TextInput, { value: target, onChange: setTarget, mono: true, autoFocus: true }) }),
        error ? jsx(ErrorBox, { error }) : null,
      ],
    }),
  });
}

function AddToGroupDialog({ seq, sam }) {
  const [group, setGroup] = useState('');
  const g = useDebounced(group.trim(), 300);
  const probe = op('ad_group_add_member', { group: g, members: [sam] });
  const dec = useApi(KEY.decision(probe), () => api.decision(probe), { enabled: !!g, staleTime: 30000 });
  const suggestions = useOp(op('ad_group_list', { query: g, limit: 20 }), { enabled: g.length >= 2, staleTime: 60000 });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  let hint = null;
  if (g && !dec.res) hint = jsx(Spinner, { label: 'Checking the policy…' });
  else if (g && !dec.res.ok) hint = jsx(ErrorBox, { error: dec.res.error });
  else if (g) {
    const d = dec.res.data;
    if (d.action === 'block') {
      hint = jsx(Callout, { tone: 'red', icon: jsx(TierTag, { tier: d.tier }), children: d.reason });
    } else if (d.tier === 'H') {
      hint = jsx(Callout, {
        tone: 'red',
        icon: jsx(TierTag, { tier: 'H' }),
        children: jsxs('div', {
          children: [jsx('b', { children: 'Privileged group.' }), ' This change escalates to high-risk: a preview and type-to-confirm are required.'],
        }),
      });
    } else {
      hint = jsx(Callout, { tone: 'accent', icon: jsx(TierTag, { tier: 'W' }), children: 'Standard group change.' });
    }
  }
  const submit = async () => {
    const name = group.trim();
    setBusy(true);
    setError(null);
    const r = await runWrite(op('ad_group_add_member', { group: name, members: [sam] }), {
      confirmed: true,
      title: `Add to ${name}`,
      confirmLabel: `Add to ${name}`,
      doneMessage: `${sam} added to ${name}`,
    });
    if (r.state === 'error') {
      setBusy(false);
      setError(r.error);
    } else if (r.state === 'done') {
      closeDialog(seq);
    }
  };
  const options = suggestions.res && suggestions.res.ok ? list(suggestions.res.data.items) : [];
  return jsx(Modal, {
    seq,
    title: `Add ${sam} to group`,
    opName: 'ad_group_add_member',
    footer: [
      jsx(Btn, { onClick: () => closeDialog(seq), disabled: busy, children: 'Cancel' }, 'cancel'),
      jsx(Btn, { kind: 'primary', onClick: submit, disabled: busy || !group.trim(), children: busy ? 'Working…' : 'Continue' }, 'ok'),
    ],
    children: jsxs('div', {
      className: 'hs-stack',
      children: [
        jsx(TextInput, { value: group, onChange: setGroup, placeholder: 'Group name', autoFocus: true, list: 'hs-group-options' }),
        jsx('datalist', { id: 'hs-group-options', children: options.map((o) => jsx('option', { value: o.name }, o.dn || o.name)) }),
        hint,
        error ? jsx(ErrorBox, { error }) : null,
      ],
    }),
  });
}

function NewUserDialog({ seq }) {
  const [template, setTemplate] = useState('');
  const [given, setGiven] = useState('');
  const [surname, setSurname] = useState('');
  const [sam, setSam] = useState('');
  const [ou, setOu] = useState('');
  const [generate, setGenerate] = useState(true);
  const [password, setPassword] = useState('');
  const [mustChange, setMustChange] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const t = useDebounced(template.trim(), 400);
  const tq = useOp(op('ad_user_get', { identity: t }), { enabled: !!t, staleTime: 60000 });
  const tpl = tq.res && tq.res.ok ? tq.res.data : null;
  const submit = async () => {
    if (!sam.trim()) {
      setError({ type: 'InvalidArguments', message: 'sAMAccountName is required.' });
      return;
    }
    if (!ou.trim() && !template.trim()) {
      setError({ type: 'InvalidArguments', message: 'Give an OU, or a template user to copy the OU from.' });
      return;
    }
    const args = { sam: sam.trim(), must_change: mustChange };
    if (given.trim()) args.given_name = given.trim();
    if (surname.trim()) args.surname = surname.trim();
    if (ou.trim()) args.ou = ou.trim();
    if (template.trim()) args.template = template.trim();
    if (!generate) args.password = password;
    setBusy(true);
    setError(null);
    const r = await runWrite(op('ad_user_create', args), {
      confirmed: true,
      title: 'Create user',
      quiet: true,
      onDone: (data) => {
        const copied = list(data.groups_copied);
        const skipped = list(data.groups_skipped);
        const details = [
          copied.length ? `Groups copied: ${copied.join(', ')}.` : '',
          skipped.length ? `Privileged groups not copied: ${skipped.join(', ')}.` : '',
          list(data.groups_failed).length ? `Groups that failed to copy: ${list(data.groups_failed).map((g) => (typeof g === 'string' ? g : g.group || g.name || JSON.stringify(g))).join(', ')}.` : '',
        ].filter(Boolean).join(' ');
        if (data.password) {
          openDialog(SecretDialog, {
            title: 'User created',
            who: data.sam || args.sam,
            secret: data.password,
            note: data.must_change ? 'A change is required at first logon.' : '',
            details,
          });
        } else {
          host.notify({ kind: 'success', message: `User ${data.sam || args.sam} created · logged to audit. ${details}` });
        }
      },
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
    title: 'New user',
    tier: 'W',
    opName: 'ad_user_create',
    footer: [
      jsx(Btn, { onClick: () => closeDialog(seq), disabled: busy, children: 'Cancel' }, 'cancel'),
      jsx(Btn, { kind: 'primary', onClick: submit, disabled: busy, children: busy ? 'Creating…' : 'Create user' }, 'ok'),
    ],
    children: jsxs('div', {
      className: 'hs-stack',
      children: [
        jsx(Field, { label: 'Copy from template user (sAMAccountName, optional)', children: jsx(TextInput, { value: template, onChange: setTemplate, mono: true, placeholder: 'rpatel' }) }),
        jsxs('div', {
          className: 'hs-two',
          children: [
            jsx(Field, { label: 'First name', children: jsx(TextInput, { value: given, onChange: setGiven, placeholder: 'Jane' }) }),
            jsx(Field, { label: 'Last name', children: jsx(TextInput, { value: surname, onChange: setSurname, placeholder: 'Doe' }) }),
          ],
        }),
        jsx(Field, { label: 'sAMAccountName', children: jsx(TextInput, { value: sam, onChange: setSam, mono: true, placeholder: 'jdoe' }) }),
        jsx(Field, {
          label: 'OU (distinguished name)',
          children: jsx(TextInput, { value: ou, onChange: setOu, mono: true, placeholder: tpl ? `${tpl.ou} (from template)` : 'OU=Staff,DC=corp,DC=example,DC=local' }),
        }),
        tpl
          ? jsx('div', {
              className: 'hs-muted hs-small',
              children: `Groups copied from template: ${list(tpl.groups).join(', ') || 'none'}. Privileged groups are never copied.`,
            })
          : t && tq.res && !tq.res.ok
            ? jsx(ErrorBox, { error: tq.res.error })
            : null,
        jsx(CheckRow, { checked: generate, onChange: setGenerate, label: 'Generate initial password (shown once)' }),
        !generate ? jsx(Field, { label: 'Initial password', children: jsx(TextInput, { type: 'password', value: password, onChange: setPassword }) }) : null,
        jsx(CheckRow, { checked: mustChange, onChange: setMustChange, label: 'Must change password at next logon' }),
        error ? jsx(ErrorBox, { error }) : null,
      ],
    }),
  });
}

function RecycleBinDialog({ seq }) {
  const [text, setText] = useState('');
  const query = useDebounced(text.trim(), 350);
  const q = useOp(op('ad_recycle_bin_list', query ? { query } : {}));
  const [busyGuid, setBusyGuid] = useState(null);
  const [error, setError] = useState(null);
  const restore = async (item) => {
    setBusyGuid(item.guid);
    setError(null);
    const r = await runWrite(op('ad_recycle_bin_restore', { identity: item.guid }), {
      confirmed: true,
      title: 'Restore from Recycle Bin',
      doneMessage: `Restored ${item.name} to ${ouPath(item.last_known_parent)}`,
    });
    setBusyGuid(null);
    if (r.state === 'error') setError(r.error);
  };
  return jsx(Modal, {
    seq,
    title: 'AD Recycle Bin',
    opName: 'ad_recycle_bin_restore',
    tier: 'W',
    wide: true,
    footer: [closeButton(seq)],
    children: jsxs('div', {
      className: 'hs-stack',
      children: [
        jsx('p', {
          className: 'hs-muted hs-small hs-p',
          children: 'Deleted objects stay restorable until the deleted-object lifetime (msDS-deletedObjectLifetime, 180 days by default) passes. Restoring puts the object back in its last known OU.',
        }),
        jsx(SearchBox, { value: text, onChange: setText, placeholder: 'Filter deleted objects…' }),
        jsx(Pending, {
          q,
          label: 'Reading the Recycle Bin…',
          children: (d) =>
            jsx(Table, {
              head: ['Object', 'Type', 'Deleted', ''],
              children: list(d.items).length
                ? list(d.items).map((item) =>
                    jsxs('tr', {
                      children: [
                        jsxs('td', { children: [item.name, jsx('div', { className: 'hs-muted hs-mono hs-tiny', children: ouPath(item.last_known_parent) })] }),
                        jsx('td', { children: item.class }),
                        jsx('td', { className: 'hs-muted', children: fmtDay(item.deleted) }),
                        jsx('td', {
                          children: jsx(Btn, { small: true, disabled: !!busyGuid, onClick: () => restore(item), children: busyGuid === item.guid ? 'Restoring…' : 'Restore' }),
                        }),
                      ],
                    }, item.guid),
                  )
                : jsx(EmptyRow, { cols: 4, text: 'The Recycle Bin is empty (or not enabled for this forest)' }),
            }),
        }),
        error ? jsx(ErrorBox, { error }) : null,
      ],
    }),
  });
}

