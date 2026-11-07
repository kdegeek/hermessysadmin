// ============================================================================
// §13 TAB: BACKUPS
// ============================================================================
const BACKUP_STATE = {
  ok: { tone: 'green', label: 'OK', card: '' },
  bad: { tone: 'red', label: 'Needs attention', card: 'bad' },
  run: { tone: 'accent', label: 'Running', card: '' },
  none: { tone: undefined, label: 'Not configured', card: 'warn' },
};

// Polls the job while it runs. backup_status is cached on the server for 60 s and a job
// finishing is not a write, so when the job ends this drops the server cache once before
// refetching, otherwise the card would keep showing "Running".
function BackupProgress({ hostName, job }) {
  const q = useOp(op('backup_jobs', { host: hostName }), { refetchInterval: POLL.job, staleTime: 0 });
  const live = q.res && q.res.ok ? q.res.data.current : job;
  const running = !!(live && live.running);
  // Treat the job as ended only after this card has itself seen it running: a cached or
  // too-early backup_jobs result (job not registered yet) must not count as "finished".
  const seenRunning = useRef(false);
  const ended = useRef(false);
  useEffect(() => {
    if (!(q.res && q.res.ok)) return;
    if (running) {
      seenRunning.current = true;
      ended.current = false;
    } else if (seenRunning.current && !ended.current) {
      ended.current = true;
      api.refresh().then(() => invalidateAll());
    }
  }, [q.res, running]);
  const pct = live && typeof live.percent === 'number' ? Math.max(0, Math.min(100, live.percent)) : 0;
  return jsxs('div', {
    children: [
      jsx('div', { className: 'hs-bar', children: jsx('i', { style: { width: `${pct}%` } }) }),
      jsx('div', { className: 'hs-muted hs-tiny', children: live ? `${live.operation || live.type || 'Backup'} · ${pct}% · started ${ago(live.started)}` : 'Waiting for progress…' }),
    ],
  });
}

function BackupCard({ row }) {
  const st = BACKUP_STATE[row.state] || BACKUP_STATE.none;
  const running = row.state === 'run' || !!(row.job && row.job.running);
  return jsxs('div', {
    className: `hs-hcard ${st.card}`,
    children: [
      jsxs('div', {
        className: 'hs-top',
        children: [jsx('b', { className: 'hs-mono', children: shortHost(row.host) }), jsx(Badge, { tone: st.tone, children: st.label })],
      }),
      row.message ? jsx('div', { className: row.state === 'bad' ? 'hs-text-red hs-small' : 'hs-muted hs-small', children: row.message }) : null,
      running ? jsx(BackupProgress, { hostName: row.host, job: row.job }) : null,
      jsx(KV, {
        keyWidth: 120,
        rows: [
          ['Last success', ago(row.last_success)],
          ['System state', row.last_system_state ? `${ago(row.last_system_state)}${row.stale ? ' · stale' : ''}` : 'never'],
          ['Next run', row.next_run ? fmtDate(row.next_run) : row.policy ? '—' : 'no schedule'],
          ['Target', row.target ? jsx('span', { className: 'hs-mono hs-tiny', children: row.target }) : '—'],
          ['Versions', num(row.versions)],
        ],
      }),
      jsxs('div', {
        className: 'hs-actions',
        style: { marginTop: 10 },
        children: [
          running
            ? jsx(Btn, {
                small: true,
                kind: 'danger',
                onClick: () =>
                  runWrite(op('backup_cancel', { host: row.host }), {
                    title: 'Cancel backup',
                    body: `Cancel the backup running on ${shortHost(row.host)}?`,
                    confirmLabel: 'Cancel backup',
                    destructive: true,
                    doneMessage: `Backup on ${shortHost(row.host)} cancelled`,
                  }),
                children: 'Cancel',
              })
            : jsx(Btn, { small: true, kind: 'primary', disabled: !row.installed, onClick: () => openDialog(BackupNowDialog, { row }), children: 'Back up now' }),
          jsx(Btn, { small: true, disabled: !row.installed, onClick: () => openDialog(BackupVersionsDialog, { hostName: row.host }), children: 'Versions' }),
          jsx(Btn, { small: true, disabled: !row.installed, onClick: () => openDialog(BackupPolicyDialog, { row }), children: 'Policy…' }),
        ],
      }),
    ],
  });
}

function BackupsTab() {
  const q = useOp(op('backup_status', {}), { refetchInterval: POLL.backups });
  return jsx(Pending, {
    q,
    label: 'Checking Windows Server Backup on servers…',
    children: (d) => {
      const s = d.summary || {};
      const errors = list(d.errors);
      return jsxs('div', {
        className: 'hs-stack',
        children: [
          jsxs('div', {
            className: 'hs-toolbar',
            children: [
              jsx('span', { className: 'hs-muted hs-small', children: `${num(s.ok)} OK · ${num(s.bad)} need attention · ${num(s.running)} running · ${num(s.not_configured)} not configured · stale after ${d.stale_days} days` }),
              jsx('span', { className: 'hs-grow' }),
              jsx(Btn, { small: true, kind: 'ghost', onClick: () => api.refresh().then(() => invalidateAll()), children: [Ico('refresh', 'i'), 'Recheck'] }),
            ],
          }),
          jsxs('div', {
            className: 'hs-hosts',
            children: [
              ...list(d.items).map((row) => jsx(BackupCard, { row }, row.host)),
              ...errors.map((e) =>
                jsxs('div', {
                  className: 'hs-hcard bad',
                  children: [
                    jsxs('div', { className: 'hs-top', children: [jsx('b', { className: 'hs-mono', children: shortHost(e.host) }), jsx(Badge, { tone: 'red', children: 'Unreachable' })] }),
                    jsx('div', { className: 'hs-muted hs-small', children: e.message }),
                  ],
                }, `err-${e.host}`),
              ),
            ],
          }),
          !list(d.items).length && !errors.length ? jsx('div', { className: 'hs-muted', children: 'No servers found.' }) : null,
        ],
      });
    },
  });
}

function BackupNowDialog({ seq, row }) {
  const [kind, setKind] = useState('system_state');
  const [target, setTarget] = useState('');
  const [volumes, setVolumes] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const submit = async () => {
    const args = { host: row.host, kind };
    if (target.trim()) args.target = target.trim();
    if (kind === 'volumes') args.volumes = splitList(volumes);
    setBusy(true);
    setError(null);
    const r = await runWrite(op('backup_start', args), {
      confirmed: true,
      title: `Back up ${shortHost(row.host)}`,
      doneMessage: `Backup started on ${shortHost(row.host)}`,
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
    title: `Back up ${shortHost(row.host)} now`,
    tier: 'W',
    opName: 'backup_start',
    footer: [
      jsx(Btn, { onClick: () => closeDialog(seq), disabled: busy, children: 'Cancel' }, 'cancel'),
      jsx(Btn, { kind: 'primary', onClick: submit, disabled: busy || (kind === 'volumes' && !splitList(volumes).length), children: 'Start backup' }, 'ok'),
    ],
    children: jsxs('div', {
      className: 'hs-stack',
      children: [
        jsx(Seg, { value: kind, options: [['system_state', 'System state'], ['policy', 'Scheduled policy'], ['volumes', 'Volumes']], onChange: setKind }),
        kind === 'volumes' ? jsx(Field, { label: 'Volumes (comma separated)', children: jsx(TextInput, { value: volumes, onChange: setVolumes, mono: true, placeholder: 'C:, D:' }) }) : null,
        kind !== 'policy'
          ? jsx(Field, { label: 'Target (optional; defaults to the policy target)', children: jsx(TextInput, { value: target, onChange: setTarget, mono: true, placeholder: row.target || 'E: or \\\\NAS01\\wsb' }) })
          : null,
        jsx('p', { className: 'hs-muted hs-small hs-p', children: 'The backup runs as a job on the server. Progress shows on the card and you can cancel it there.' }),
        error ? jsx(ErrorBox, { error }) : null,
      ],
    }),
  });
}

function BackupVersionsDialog({ seq, hostName }) {
  const versions = useOp(op('backup_versions', { host: hostName }));
  const jobs = useOp(op('backup_jobs', { host: hostName }));
  return jsx(InfoDialog, {
    seq,
    title: `Backups on ${shortHost(hostName)}`,
    wide: true,
    children: jsxs('div', {
      className: 'hs-stack',
      children: [
        jsx('div', { className: 'hs-label', children: 'Versions' }),
        jsx(Pending, {
          q: versions,
          label: 'Reading backup versions…',
          children: (d) =>
            jsx(Table, {
              head: ['Time', 'Target', 'Recoverable', 'Volumes'],
              children: list(d.items).length
                ? list(d.items).map((v) =>
                    jsxs('tr', {
                      children: [
                        jsx('td', { children: fmtDate(v.time) }),
                        jsx('td', { className: 'hs-mono hs-tiny', children: v.target }),
                        jsx('td', { className: 'hs-muted', children: String(v.recoverable || '—') }),
                        jsx('td', { className: 'hs-muted', children: list(v.volumes).join(', ') }),
                      ],
                    }, v.version_id),
                  )
                : jsx(EmptyRow, { cols: 4, text: 'No backup versions' }),
            }),
        }),
        jsx('div', { className: 'hs-label', children: 'Recent backup events' }),
        jsx(Pending, {
          q: jobs,
          label: 'Reading backup events…',
          children: (d) =>
            jsx(Table, {
              head: ['Time', 'Outcome', 'Message'],
              children: list(d.history).length
                ? list(d.history).slice(0, 15).map((h, i) =>
                    jsxs('tr', {
                      children: [
                        jsx('td', { className: 'hs-nowrap', children: fmtDate(h.time) }),
                        jsx('td', { children: jsx(Badge, { tone: h.outcome === 'succeeded' || h.outcome === 'completed' ? 'green' : h.outcome === 'failed' ? 'red' : undefined, children: h.outcome }) }),
                        jsx('td', { className: 'hs-muted hs-tiny', children: h.message }),
                      ],
                    }, `${h.id}-${i}`),
                  )
                : jsx(EmptyRow, { cols: 3, text: 'No backup events' }),
            }),
        }),
      ],
    }),
  });
}

function BackupPolicyDialog({ seq, row }) {
  const [schedule, setSchedule] = useState('23:00');
  const [target, setTarget] = useState(row.target || '');
  const [systemState, setSystemState] = useState(true);
  const [bareMetal, setBareMetal] = useState(false);
  const [volumes, setVolumes] = useState('');
  const times = splitList(schedule);
  const valid = times.length > 0 && times.every((t) => /^([01]?\d|2[0-3]):[0-5]\d$/.test(t)) && !!target.trim();
  const next = () => {
    const args = { host: row.host, schedule: times, target: target.trim(), system_state: systemState, bare_metal: bareMetal };
    if (splitList(volumes).length) args.volumes = splitList(volumes);
    runWrite(op('backup_set_policy', args), {
      title: `Backup policy · ${shortHost(row.host)}`,
      confirmLabel: 'Replace policy',
      doneMessage: `Backup policy on ${shortHost(row.host)} replaced`,
    });
  };
  return jsx(Modal, {
    seq,
    title: `Backup policy · ${shortHost(row.host)}`,
    tier: 'H',
    opName: 'backup_set_policy',
    footer: [
      jsx(Btn, { onClick: () => closeDialog(seq), children: 'Cancel' }, 'cancel'),
      jsx(Btn, { kind: 'danger', onClick: next, disabled: !valid, children: 'Preview change…' }, 'ok'),
    ],
    children: jsxs('div', {
      className: 'hs-stack',
      children: [
        jsx('p', { className: 'hs-p', children: 'This replaces the scheduled Windows Server Backup policy. The next step shows the current and new policy and asks you to type the server name.' }),
        jsx(Field, { label: 'Daily start times (HH:mm, comma separated)', children: jsx(TextInput, { value: schedule, onChange: setSchedule, mono: true }) }),
        jsx(Field, { label: 'Target volume or share', children: jsx(TextInput, { value: target, onChange: setTarget, mono: true, placeholder: 'E: or \\\\NAS01\\wsb\\SRV1' }) }),
        jsx(CheckRow, { checked: systemState, onChange: setSystemState, label: 'Include system state' }),
        jsx(CheckRow, { checked: bareMetal, onChange: setBareMetal, label: 'Include bare-metal recovery' }),
        jsx(Field, { label: 'Extra volumes (optional, comma separated)', children: jsx(TextInput, { value: volumes, onChange: setVolumes, mono: true, placeholder: 'D:' }) }),
      ],
    }),
  });
}

