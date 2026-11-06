// ============================================================================
// §11 TAB: GROUP POLICY
// ============================================================================
const SETTINGS_PER_SECTION = 12;

function gpoMatches(g, f) {
  if (f.attention && !list(g.health).length) return false;
  if (f.unlinked && list(g.links).length) return false;
  if (f.enforced && !list(g.links).some((l) => l.enforced)) return false;
  if (!f.text) return true;
  const t = f.text.toLowerCase();
  return [g.name, g.description, g.owner].some((v) => String(v || '').toLowerCase().includes(t)) ||
    list(g.links).some((l) => String(l.target || '').toLowerCase().includes(t));
}

function linkSummary(g) {
  const links = list(g.links);
  if (!links.length) return jsx('span', { className: 'hs-text-yellow', children: 'not linked' });
  const first = shortDn(links[0].target);
  return jsxs('span', {
    children: [
      first,
      links.length > 1 ? jsx('span', { className: 'hs-muted', children: ` +${links.length - 1}` }) : null,
      links.some((l) => l.enforced) ? ' ' : null,
      links.some((l) => l.enforced) ? jsx(Badge, { tone: 'accent', children: 'enforced' }) : null,
    ],
  });
}

function GpoTab() {
  const [text, setText] = useState('');
  const [attention, setAttention] = useState(false);
  const [unlinked, setUnlinked] = useState(false);
  const [enforced, setEnforced] = useState(false);
  const [selected, setSelected] = useState(null);
  const q = useOp(op('gpo_list', {}), { refetchInterval: POLL.list });
  return jsxs('div', {
    children: [
      jsxs('div', {
        className: 'hs-toolbar',
        children: [
          jsx(SearchBox, { value: text, onChange: setText, placeholder: 'Search GPOs, links, owners…' }),
          jsx(Chip, { on: attention, onClick: () => setAttention(!attention), children: 'Needs attention' }),
          jsx(Chip, { on: unlinked, onClick: () => setUnlinked(!unlinked), children: 'Unlinked' }),
          jsx(Chip, { on: enforced, onClick: () => setEnforced(!enforced), children: 'Enforced' }),
          jsx('span', { className: 'hs-grow' }),
          jsx(Btn, { onClick: () => openDialog(GpUpdateDialog, {}), children: '⟳ Run gpupdate…' }),
          jsx(Btn, { kind: 'primary', onClick: () => openDialog(NewGpoDialog, {}), children: '+ New GPO' }),
        ],
      }),
      jsx(Pending, {
        q,
        label: 'Reading Group Policy objects…',
        children: (d) => {
          const all = list(d.items);
          const rows = all.filter((g) => gpoMatches(g, { text: text.trim(), attention, unlinked, enforced }));
          const current = all.find((g) => g.id === selected) || rows[0] || null;
          const s = d.summary || {};
          return jsxs('div', {
            className: 'hs-grid2 hs-gpo',
            children: [
              jsx(Card, {
                title: 'Group Policy objects',
                sub: `${num(s.total)} total · ${num(s.needs_attention)} need attention · ${num(s.unlinked)} unlinked`,
                children: jsx(Table, {
                  head: ['Name', 'Status', 'Linked to', 'Modified', 'Health'],
                  children: rows.length
                    ? rows.map((g) =>
                        jsxs('tr', {
                          className: `click${current && current.id === g.id ? ' sel' : ''}`,
                          onClick: () => setSelected(g.id),
                          children: [
                            jsx('td', { children: jsx('b', { children: g.name }) }),
                            jsx('td', {
                              children: g.status === 'AllSettingsEnabled'
                                ? jsx('span', { className: 'hs-muted', children: GPO_STATUS[g.status] })
                                : jsx(Badge, { tone: 'yellow', children: GPO_STATUS[g.status] || g.status }),
                            }),
                            jsx('td', { children: linkSummary(g) }),
                            jsx('td', { className: 'hs-muted', children: fmtDay(g.modified) }),
                            jsx('td', {
                              children: list(g.health).length
                                ? jsx(Badge, { tone: 'yellow', title: list(g.health).join('\n'), children: `⚠ ${list(g.health)[0]}${list(g.health).length > 1 ? ` +${list(g.health).length - 1}` : ''}` })
                                : jsx(Badge, { tone: 'green', children: 'OK' }),
                            }),
                          ],
                        }, g.id),
                      )
                    : jsx(EmptyRow, { cols: 5, text: 'No GPOs match these filters' }),
                }),
              }),
              current ? jsx(GpoDetail, { gpo: current }, current.id) : jsx(Card, { title: 'Details', children: jsx('div', { className: 'hs-card-body hs-muted', children: 'Select a GPO.' }) }),
            ],
          });
        },
      }),
    ],
  });
}

function setLink(gpo, link, patch) {
  const words = [];
  if ('enforced' in patch) words.push(patch.enforced ? 'enforce' : 'stop enforcing');
  if ('enabled' in patch) words.push(patch.enabled ? 'enable' : 'disable');
  const what = words.join(' and ');
  return runWrite(op('gpo_set_link', { identity: gpo.name, target: link.target, enforced: 'enforced' in patch ? patch.enforced : !!link.enforced, enabled: 'enabled' in patch ? patch.enabled : !!link.enabled }), {
    title: 'Change GPO link',
    body: `${what.charAt(0).toUpperCase()}${what.slice(1)} the link of "${gpo.name}" on ${shortDn(link.target)}?`,
    confirmLabel: 'Apply',
    doneMessage: `Link on ${shortDn(link.target)} updated`,
  });
}

function unlinkGpo(gpo, link) {
  return runWrite(op('gpo_unlink', { identity: gpo.name, target: link.target }), {
    title: 'Unlink GPO',
    body: `Remove the link of "${gpo.name}" from ${shortDn(link.target)}? Its settings stop applying there at the next policy refresh.`,
    confirmLabel: 'Unlink',
    destructive: true,
    doneMessage: `"${gpo.name}" unlinked from ${shortDn(link.target)}`,
  });
}

function backupGpo(gpo) {
  return runWrite(op('gpo_backup', { identity: gpo.name, comment: 'hermes-sysadmin backup (dashboard)' }), {
    title: 'Back up GPO',
    body: `Back up "${gpo.name}" on the domain controller now?`,
    confirmLabel: 'Back up',
    doneMessage: `"${gpo.name}" backed up`,
  });
}

async function openHtmlReport(gpo) {
  const r = await api.read(op('gpo_report', { identity: gpo.name, format: 'html' }));
  if (!r.ok) {
    openDialog(ErrorDialog, { title: 'GPO report', error: r.error });
    return;
  }
  const saved = await saveText(`${safeName(gpo.name)}-report.html`, String(r.data.html || ''));
  host.notify({ kind: saved.ok ? 'info' : 'error', message: savedMessage('GPO report', saved) });
}

function GpoSettings({ q }) {
  const [open, setOpen] = useState({});
  if (!q.res) return jsx(Spinner, { label: 'Reading settings…' });
  if (!q.res.ok) return jsx(ErrorBox, { error: q.res.error });
  const sections = list(q.res.data.sections);
  if (!sections.length) return jsx('div', { className: 'hs-muted', children: 'No configured settings.' });
  return jsx('div', {
    className: 'hs-stack',
    children: sections.map((sec, i) => {
      const key = `${sec.scope}-${sec.extension}-${i}`;
      const all = list(sec.settings);
      const shown = open[key] ? all : all.slice(0, SETTINGS_PER_SECTION);
      return jsxs('div', {
        children: [
          jsx('div', { className: 'hs-label', children: `${sec.scope} · ${sec.extension}` }),
          jsx(Table, {
            children: shown.map((s, j) =>
              jsxs('tr', {
                children: [
                  jsx('td', { children: s.name }),
                  jsx('td', { className: 'hs-muted', children: s.value !== undefined && s.value !== null && s.value !== '' ? String(s.value) : s.state || '' }),
                ],
              }, j),
            ),
          }),
          all.length > shown.length
            ? jsx(Btn, { kind: 'ghost', small: true, onClick: () => setOpen({ ...open, [key]: true }), children: `+${all.length - shown.length} more` })
            : null,
        ],
      }, key);
    }),
  });
}

function GpoDetail({ gpo }) {
  const get = useOp(op('gpo_get', { identity: gpo.name }));
  const report = useOp(op('gpo_report', { identity: gpo.name, format: 'summary' }), { staleTime: 60000 });
  const backups = useOp(op('gpo_backups', { identity: gpo.name }));
  const g = get.res && get.res.ok ? { ...gpo, ...get.res.data } : gpo;
  const links = list(g.links);
  const filtering = list(g.security_filtering);
  const backupItems = backups.res && backups.res.ok ? list(backups.res.data.items) : [];
  return jsx(Card, {
    title: g.name,
    sub: g.description || '',
    children: jsxs('div', {
      children: [
        jsx('div', {
          className: 'hs-sec',
          children: jsxs('div', {
            className: 'hs-actions',
            children: [
              jsx(Btn, { small: true, onClick: () => openDialog(LinkGpoDialog, { gpo: g }), children: 'Link…' }),
              jsx(Btn, { small: true, onClick: () => openDialog(GpoStatusDialog, { gpo: g }), children: 'Status…' }),
              jsx(Btn, { small: true, onClick: () => openDialog(SecurityFilterDialog, { gpo: g, current: filtering }), children: 'Security filter…' }),
              jsx(Btn, { small: true, onClick: () => backupGpo(g), children: 'Back up' }),
              jsx(Btn, { small: true, disabled: !backupItems.length, title: backupItems.length ? '' : 'No backups yet', onClick: () => openDialog(RestoreGpoDialog, { gpo: g, backups: backupItems }), children: 'Restore…' }),
              jsx(Btn, {
                small: true,
                kind: 'danger',
                onClick: () =>
                  runWrite(op('gpo_delete', { identity: g.name }), { title: 'Delete GPO', confirmLabel: 'Delete GPO', doneMessage: `"${g.name}" deleted (a safety backup was taken first)` }),
                children: 'Delete',
              }),
            ],
          }),
        }),
        list(g.health).length
          ? jsx('div', {
              className: 'hs-sec',
              children: jsx(Callout, { tone: 'yellow', icon: '⚠', children: jsx('div', { children: list(g.health).map((h) => jsx('div', { children: h }, h)) }) }),
            })
          : null,
        jsxs('div', {
          className: 'hs-sec',
          children: [
            jsx('h4', { children: 'Overview' }),
            jsx(KV, {
              rows: [
                ['Status', GPO_STATUS[g.status] || g.status || '—'],
                ['Owner', g.owner || '—'],
                ['Created', fmtDay(g.created)],
                ['Modified', fmtDate(g.modified)],
                ['WMI filter', g.wmi_filter || 'none'],
                ['Computer version', g.computer_version ? `AD ${g.computer_version.ad} · SYSVOL ${g.computer_version.sysvol}` : '—'],
                ['User version', g.user_version ? `AD ${g.user_version.ad} · SYSVOL ${g.user_version.sysvol}` : '—'],
                ['GUID', jsx('span', { className: 'hs-mono hs-tiny', children: g.id })],
              ],
            }),
          ],
        }),
        jsxs('div', {
          className: 'hs-sec',
          children: [
            jsx('h4', { children: `Links (${links.length})` }),
            links.length
              ? jsx(Table, {
                  head: ['Target', 'Order', 'State', ''],
                  children: links.map((l) =>
                    jsxs('tr', {
                      children: [
                        jsx('td', { title: l.target, children: shortDn(l.target) }),
                        jsx('td', { className: 'hs-muted', children: l.order }),
                        jsxs('td', {
                          children: [
                            l.enabled ? jsx(Badge, { tone: 'green', children: 'enabled' }) : jsx(Badge, { children: 'disabled' }),
                            l.enforced ? ' ' : null,
                            l.enforced ? jsx(Badge, { tone: 'accent', children: 'enforced' }) : null,
                          ],
                        }),
                        jsx('td', {
                          className: 'hs-nowrap',
                          children: jsxs('div', {
                            className: 'hs-actions',
                            children: [
                              jsx(Btn, { small: true, kind: 'ghost', onClick: () => setLink(g, l, { enforced: !l.enforced }), children: l.enforced ? 'Unenforce' : 'Enforce' }),
                              jsx(Btn, { small: true, kind: 'ghost', onClick: () => setLink(g, l, { enabled: !l.enabled }), children: l.enabled ? 'Disable' : 'Enable' }),
                              jsx(Btn, { small: true, kind: 'danger', onClick: () => unlinkGpo(g, l), children: 'Unlink' }),
                            ],
                          }),
                        }),
                      ],
                    }, l.target),
                  ),
                })
              : jsx('div', { className: 'hs-muted', children: 'Not linked anywhere.' }),
          ],
        }),
        jsxs('div', {
          className: 'hs-sec',
          children: [
            jsx('h4', { children: 'Security filtering' }),
            !get.res
              ? jsx(Spinner, { label: 'Reading permissions…' })
              : !get.res.ok
                ? jsx(ErrorBox, { error: get.res.error })
                : jsx('div', {
                    className: 'hs-actions',
                    children: filtering.length ? filtering.map((p) => jsx(Badge, { children: p }, p)) : jsx('span', { className: 'hs-text-yellow', children: 'Applies to nobody' }),
                  }),
          ],
        }),
        jsxs('div', {
          className: 'hs-sec',
          children: [
            jsxs('h4', {
              children: [
                'Settings',
                jsx('span', { className: 'hs-grow' }),
                jsx(Btn, { small: true, kind: 'ghost', onClick: () => openHtmlReport(g), children: 'Open full HTML report ↗' }),
              ],
            }),
            jsx(GpoSettings, { q: report }),
          ],
        }),
        jsxs('div', {
          className: 'hs-sec',
          children: [
            jsx('h4', { children: 'Backups' }),
            !backups.res
              ? jsx(Spinner, { label: 'Reading backups…' })
              : !backups.res.ok
                ? jsx(ErrorBox, { error: backups.res.error })
                : backupItems.length
                  ? jsx('div', {
                      children: backupItems.slice(0, 5).map((b) =>
                        jsxs('div', { className: 'hs-row hs-small', children: [jsx('span', { children: fmtDate(b.time) }), jsx('span', { className: 'hs-muted', children: b.comment || '' })] }, b.backup_id),
                      ),
                    })
                  : jsx('span', { className: 'hs-muted', children: 'No backups taken by this plugin yet.' }),
          ],
        }),
      ],
    }),
  });
}

async function gpupdateAfter(args, title) {
  const r = await runWrite(op('gpo_update_hosts', args), {
    confirmed: true,
    quiet: true,
    title,
    onDone: (data) => openDialog(GpUpdateResultDialog, { data }),
  });
  if (r.state === 'error') openDialog(ErrorDialog, { title, error: r.error });
  return r;
}

function GpUpdateDialog({ seq }) {
  const [mode, setMode] = useState('hosts');
  const [hosts, setHosts] = useState('');
  const [ou, setOu] = useState('');
  const [force, setForce] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const submit = async () => {
    const args = { force };
    if (mode === 'hosts') args.computers = splitList(hosts);
    else args.ou = ou.trim();
    setBusy(true);
    setError(null);
    const r = await runWrite(op('gpo_update_hosts', args), {
      confirmed: true,
      quiet: true,
      title: 'Run gpupdate',
      onDone: (data) => openDialog(GpUpdateResultDialog, { data }),
    });
    if (r.state === 'error') {
      setBusy(false);
      setError(r.error);
    }
  };
  const ready = mode === 'hosts' ? splitList(hosts).length > 0 : !!ou.trim();
  return jsx(Modal, {
    seq,
    title: 'Run gpupdate',
    tier: 'W',
    opName: 'gpo_update_hosts',
    footer: [
      jsx(Btn, { onClick: () => closeDialog(seq), disabled: busy, children: 'Cancel' }, 'cancel'),
      jsx(Btn, { kind: 'primary', onClick: submit, disabled: busy || !ready, children: busy ? 'Running…' : 'Run gpupdate' }, 'ok'),
    ],
    children: jsxs('div', {
      className: 'hs-stack',
      children: [
        jsx(Seg, { value: mode, options: [['hosts', 'Computers'], ['ou', 'Every computer in an OU']], onChange: setMode }),
        mode === 'hosts'
          ? jsx(Field, { label: 'Computer DNS names (comma or newline separated)', children: jsx(TextArea, { value: hosts, onChange: setHosts, mono: true, placeholder: 'ws-0142.corp.example.local' }) })
          : jsx(Field, { label: 'OU (distinguished name)', children: jsx(TextInput, { value: ou, onChange: setOu, mono: true, placeholder: 'OU=Workstations,DC=corp,DC=example,DC=local' }) }),
        jsx(CheckRow, { checked: force, onChange: setForce, label: 'Use /force (reapply every setting)' }),
        error ? jsx(ErrorBox, { error }) : null,
      ],
    }),
  });
}

function GpUpdateResultDialog({ seq, data }) {
  const results = list(data.results);
  const errors = list(data.errors);
  const failed = results.filter((r) => !r.ok).length;
  return jsx(InfoDialog, {
    seq,
    title: `gpupdate · ${results.length - failed} of ${results.length} succeeded`,
    wide: true,
    children: jsxs('div', {
      className: 'hs-stack',
      children: [
        jsx(Table, {
          head: ['Computer', 'Result', 'Output'],
          children: results.length
            ? results.map((r) =>
                jsxs('tr', {
                  children: [
                    jsx('td', { className: 'hs-mono', children: shortHost(r.host) }),
                    jsx('td', { children: r.ok ? jsx(Badge, { tone: 'green', children: 'ok' }) : jsx(Badge, { tone: 'red', children: `exit ${r.exit_code}` }) }),
                    jsx('td', { className: 'hs-muted hs-tiny', children: String(r.output || '').slice(0, 300) }),
                  ],
                }, r.host),
              )
            : jsx(EmptyRow, { cols: 3, text: 'No computers were targeted' }),
        }),
        errors.length
          ? jsx(Callout, { tone: 'red', icon: '⚠', children: jsx('div', { children: errors.map((e, i) => jsx('div', { children: `${shortHost(e.host)}: ${e.message}` }, i)) }) })
          : null,
      ],
    }),
  });
}

function NewGpoDialog({ seq }) {
  const [name, setName] = useState('');
  const [comment, setComment] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const submit = async () => {
    const args = { name: name.trim() };
    if (comment.trim()) args.comment = comment.trim();
    setBusy(true);
    setError(null);
    const r = await runWrite(op('gpo_create', args), { confirmed: true, title: 'New GPO', doneMessage: `GPO "${args.name}" created (not linked yet)` });
    if (r.state === 'error') {
      setBusy(false);
      setError(r.error);
    } else if (r.state === 'done') {
      closeDialog(seq);
    }
  };
  return jsx(Modal, {
    seq,
    title: 'New GPO',
    tier: 'W',
    opName: 'gpo_create',
    footer: [
      jsx(Btn, { onClick: () => closeDialog(seq), disabled: busy, children: 'Cancel' }, 'cancel'),
      jsx(Btn, { kind: 'primary', onClick: submit, disabled: busy || !name.trim(), children: 'Create' }, 'ok'),
    ],
    children: jsxs('div', {
      className: 'hs-stack',
      children: [
        jsx(Field, { label: 'Display name', children: jsx(TextInput, { value: name, onChange: setName, autoFocus: true, onEnter: submit }) }),
        jsx(Field, { label: 'Description (optional)', children: jsx(TextInput, { value: comment, onChange: setComment }) }),
        jsx('p', { className: 'hs-muted hs-small hs-p', children: 'The GPO is created empty and unlinked; link it when it is ready.' }),
        error ? jsx(ErrorBox, { error }) : null,
      ],
    }),
  });
}

function LinkGpoDialog({ seq, gpo }) {
  const [target, setTarget] = useState('');
  const [enforced, setEnforced] = useState(false);
  const [backupFirst, setBackupFirst] = useState(true);
  const [testHost, setTestHost] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const submit = async () => {
    const t = target.trim();
    const test = testHost.trim();
    setBusy(true);
    setError(null);
    if (backupFirst) {
      const b = await runWrite(op('gpo_backup', { identity: gpo.name, comment: `before link to ${shortDn(t)}` }), { confirmed: true, quiet: true, title: 'Back up GPO' });
      if (b.state !== 'done') {
        setBusy(false);
        setError(b.error || { type: 'InternalError', message: 'The safety backup did not run.' });
        return;
      }
    }
    const r = await runWrite(op('gpo_link', { identity: gpo.name, target: t, enforced, enabled: true }), {
      confirmed: true,
      title: `Link "${gpo.name}"`,
      confirmLabel: 'Link GPO',
      doneMessage: `"${gpo.name}" linked to ${shortDn(t)}${backupFirst ? ' · backup taken first' : ''}`,
      onDone: () => {
        if (test) gpupdateAfter({ computers: [test], force: true }, 'Test gpupdate');
      },
    });
    if (r.state === 'error') {
      setBusy(false);
      setError(r.error);
    } else if (r.state === 'done' && !test) {
      closeDialog(seq);
    }
  };
  return jsx(Modal, {
    seq,
    title: `Link "${gpo.name}"`,
    opName: 'gpo_link',
    footer: [
      jsx(Btn, { onClick: () => closeDialog(seq), disabled: busy, children: 'Cancel' }, 'cancel'),
      jsx(Btn, { kind: 'primary', onClick: submit, disabled: busy || !target.trim(), children: busy ? 'Working…' : 'Link' }, 'ok'),
    ],
    children: jsxs('div', {
      className: 'hs-stack',
      children: [
        jsx(Field, { label: 'Link to (OU, domain or site distinguished name)', children: jsx(TextInput, { value: target, onChange: setTarget, mono: true, autoFocus: true, placeholder: 'OU=Workstations,DC=corp,DC=example,DC=local' }) }),
        jsx(Callout, {
          tone: 'accent',
          icon: jsx(TierTag, { tier: 'W' }),
          children: 'Linking at the domain root, the Domain Controllers OU or a site escalates to high-risk: you will see a preview and type the GPO name to confirm.',
        }),
        jsx(CheckRow, { checked: enforced, onChange: setEnforced, label: 'Enforce the link' }),
        jsx(CheckRow, { checked: backupFirst, onChange: setBackupFirst, label: 'Back up the GPO first' }),
        jsx(Field, { label: 'Then run gpupdate on a test computer (optional)', children: jsx(TextInput, { value: testHost, onChange: setTestHost, mono: true, placeholder: 'ws-test01.corp.example.local' }) }),
        error ? jsx(ErrorBox, { error }) : null,
      ],
    }),
  });
}

function GpoStatusDialog({ seq, gpo }) {
  const [status, setStatus] = useState(gpo.status || 'AllSettingsEnabled');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const submit = async () => {
    setBusy(true);
    setError(null);
    const r = await runWrite(op('gpo_set_status', { identity: gpo.name, status }), {
      confirmed: true,
      title: `Status of "${gpo.name}"`,
      confirmLabel: 'Change status',
      doneMessage: `"${gpo.name}": ${GPO_STATUS[status]}`,
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
    title: `Status of "${gpo.name}"`,
    tier: 'W',
    opName: 'gpo_set_status',
    footer: [
      jsx(Btn, { onClick: () => closeDialog(seq), disabled: busy, children: 'Cancel' }, 'cancel'),
      jsx(Btn, { kind: 'primary', onClick: submit, disabled: busy || status === gpo.status, children: 'Apply' }, 'ok'),
    ],
    children: jsxs('div', {
      className: 'hs-stack',
      children: [
        jsx('div', {
          className: 'hs-stack',
          children: Object.keys(GPO_STATUS).map((s) =>
            jsxs('label', {
              className: 'hs-radio',
              children: [jsx('input', { type: 'radio', name: 'hs-gpo-status', checked: status === s, onChange: () => setStatus(s) }), ' ', GPO_STATUS[s]],
            }, s),
          ),
        }),
        jsx('p', { className: 'hs-muted hs-small hs-p', children: 'Changing the Default Domain Policy or Default Domain Controllers Policy is high-risk.' }),
        error ? jsx(ErrorBox, { error }) : null,
      ],
    }),
  });
}

function SecurityFilterDialog({ seq, gpo, current }) {
  const [add, setAdd] = useState('');
  const [remove, setRemove] = useState([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const toggle = (p, on) => setRemove(on ? [...remove, p] : remove.filter((x) => x !== p));
  const adds = splitList(add);
  const submit = async () => {
    setBusy(true);
    setError(null);
    const r = await runWrite(op('gpo_set_security_filter', { identity: gpo.name, add: adds, remove }), {
      confirmed: true,
      title: `Security filtering of "${gpo.name}"`,
      confirmLabel: 'Apply',
      doneMessage: `Security filtering of "${gpo.name}" updated`,
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
    title: `Security filtering · ${gpo.name}`,
    tier: 'W',
    opName: 'gpo_set_security_filter',
    footer: [
      jsx(Btn, { onClick: () => closeDialog(seq), disabled: busy, children: 'Cancel' }, 'cancel'),
      jsx(Btn, { kind: 'primary', onClick: submit, disabled: busy || (!adds.length && !remove.length), children: 'Apply' }, 'ok'),
    ],
    children: jsxs('div', {
      className: 'hs-stack',
      children: [
        jsx('div', { className: 'hs-label', children: 'Currently applies to (tick to remove)' }),
        jsx('div', {
          className: 'hs-stack',
          children: list(current).length
            ? list(current).map((p) => jsx(CheckRow, { checked: remove.includes(p), onChange: (on) => toggle(p, on), label: p }, p))
            : jsx('span', { className: 'hs-muted', children: 'Nobody' }),
        }),
        jsx(Field, { label: 'Grant Apply to (groups, users or computers; comma separated)', children: jsx(TextInput, { value: add, onChange: setAdd, placeholder: 'Finance-Laptops' }) }),
        error ? jsx(ErrorBox, { error }) : null,
      ],
    }),
  });
}

function RestoreGpoDialog({ seq, gpo, backups }) {
  const [pick, setPick] = useState(backups[0] ? backups[0].backup_id : '');
  const next = () =>
    runWrite(op('gpo_restore', { identity: gpo.name, backup_id: pick }), {
      title: `Restore "${gpo.name}"`,
      confirmLabel: 'Restore GPO',
      doneMessage: `"${gpo.name}" restored (a safety backup was taken first)`,
    });
  return jsx(Modal, {
    seq,
    title: `Restore "${gpo.name}"`,
    tier: 'H',
    opName: 'gpo_restore',
    footer: [
      jsx(Btn, { onClick: () => closeDialog(seq), children: 'Cancel' }, 'cancel'),
      jsx(Btn, { kind: 'danger', onClick: next, disabled: !pick, children: 'Continue…' }, 'ok'),
    ],
    children: jsxs('div', {
      className: 'hs-stack',
      children: [
        jsx('p', { className: 'hs-p', children: 'Pick a backup. The current state is backed up before the restore runs.' }),
        jsx('div', {
          className: 'hs-stack',
          children: backups.map((b) =>
            jsxs('label', {
              className: 'hs-radio',
              children: [jsx('input', { type: 'radio', name: 'hs-gpo-backup', checked: pick === b.backup_id, onChange: () => setPick(b.backup_id) }), ' ', fmtDate(b.time), jsx('span', { className: 'hs-muted', children: ` · ${b.comment || ''}` })],
            }, b.backup_id),
          ),
        }),
      ],
    }),
  });
}

