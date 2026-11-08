// ============================================================================
// §7 DIALOGS AND THE CONFIRM FLOW
// ============================================================================
// One dialog at a time, held in $dialog. Every write goes through runWrite():
//   decision → allow: run · block: show the reason, no run button ·
//   approve W: confirm dialog (or the form that collected the args) → run with confirm:true ·
//   approve H: server preview → run with confirm:true; destructive ops also type the name (confirm_name).
function DialogHost() {
  const cur = useValue($dialog);
  if (!cur) return null;
  return jsx(cur.Component, { ...cur.props, seq: cur.seq }, cur.seq);
}

function Modal({ seq, title, tier, opName, description, wide, footer, children }) {
  const sub = tier || opName || description;
  return jsx(Dialog, {
    open: true,
    onOpenChange: (open) => {
      if (!open) closeDialog(seq);
    },
    children: jsxs(DialogContent, {
      className: `hs-modal${wide ? ' hs-modal-wide' : ''}`,
      children: [
        jsxs(DialogHeader, {
          children: [
            jsx(DialogTitle, { children: title }),
            sub
              ? jsxs(DialogDescription, {
                  className: 'hs-modal-sub',
                  children: [
                    tier ? jsx(TierTag, { tier }) : null,
                    opName ? jsx('span', { className: 'hs-mono hs-muted', children: opName }) : null,
                    description ? jsx('span', { children: description }) : null,
                  ],
                })
              : null,
          ],
        }),
        jsx('div', { className: 'hs-modal-body', children }),
        footer ? jsx(DialogFooter, { children: footer }) : null,
      ],
    }),
  });
}

function closeButton(seq, label) {
  return jsx(Btn, { onClick: () => closeDialog(seq), children: label || 'Close' }, 'close');
}

function finishWrite(o, res, opts) {
  if (!res.ok) return { state: 'error', error: res.error };
  invalidateAll();
  if (!opts.quiet) {
    host.notify({ kind: 'success', message: opts.doneMessage || `${opts.title || o.name}: done · logged to audit` });
  }
  if (opts.onDone) opts.onDone(res.data || {});
  return { state: 'done', data: res.data || {} };
}

// opts: title, body, confirmLabel, destructive, doneMessage, quiet, onDone(data),
//       confirmed — true when a form dialog already showed the W tier and the user pressed its
//       action button; the form then gets {state:'error'} back to show inline.
async function runWrite(o, options) {
  const opts = options || {};
  const d = await api.decision(o);
  if (!d.ok) {
    if (opts.confirmed) return { state: 'error', error: d.error };
    openDialog(ErrorDialog, { title: opts.title || o.name, error: d.error });
    return { state: 'handed-off' };
  }
  const dec = d.data;
  if (dec.action !== 'allow' && dec.action !== 'approve') {
    // Fail closed: anything the page does not recognise is treated as a block.
    openDialog(BlockedDialog, { o, dec, opts });
    return { state: 'handed-off' };
  }
  if (dec.action === 'block') {
    openDialog(BlockedDialog, { o, dec, opts });
    return { state: 'handed-off' };
  }
  if (dec.action === 'approve' && dec.tier === 'H') {
    openDialog(HighRiskDialog, { o, dec, opts });
    return { state: 'handed-off' };
  }
  if (dec.action === 'approve' && !opts.confirmed) {
    openDialog(ConfirmWriteDialog, { o, dec, opts });
    return { state: 'handed-off' };
  }
  const res = await api.run(o, dec.action === 'approve' ? { confirm: true } : {});
  const out = finishWrite(o, res, opts);
  if (out.state === 'error' && !opts.confirmed) {
    openDialog(ErrorDialog, { title: opts.title || o.name, error: out.error });
  }
  return out;
}

function useSubmit(seq, o, body, opts) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const submit = async () => {
    setBusy(true);
    setError(null);
    const res = await api.run(o, body);
    if (!res.ok) {
      setBusy(false);
      setError(res.error);
      return;
    }
    closeDialog(seq);
    finishWrite(o, res, opts);
  };
  return { busy, error, submit };
}

// A write that ships a -Preview plan shows it before the user confirms (the server runs the script in
// preview mode: nothing changes). Its own component so the preview query only exists when it is shown.
function WritePreview({ seq, o }) {
  const pv = useApi(KEY.preview(o, seq), () => api.preview(o), { staleTime: Infinity });
  return jsxs('div', {
    className: 'hs-stack',
    children: [
      jsx('div', { className: 'hs-label', children: 'Preview · nothing has changed yet' }),
      jsx(PreviewBody, { q: pv, args: o.args }),
    ],
  });
}

function ConfirmWriteDialog({ seq, o, dec, opts }) {
  const s = useSubmit(seq, o, { confirm: true }, opts);
  return jsx(Modal, {
    seq,
    title: opts.title || 'Confirm change',
    tier: 'W',
    opName: o.name,
    wide: !!dec.can_preview,
    footer: [
      jsx(Btn, { onClick: () => closeDialog(seq), disabled: s.busy, children: 'Cancel' }, 'cancel'),
      jsx(Btn, {
        kind: opts.destructive ? 'solid-danger' : 'primary',
        onClick: s.submit,
        disabled: s.busy,
        children: s.busy ? 'Working…' : opts.confirmLabel || 'Confirm',
      }, 'ok'),
    ],
    children: jsxs('div', {
      className: 'hs-stack',
      children: [
        jsx('p', { className: 'hs-p', children: opts.body || `Run ${o.name} on ${dec.target || 'the selected object'}?` }),
        dec.target ? jsxs('div', { className: 'hs-muted hs-small', children: ['Target: ', jsx('span', { className: 'hs-mono', children: dec.target })] }) : null,
        dec.can_preview ? jsx(WritePreview, { seq, o }) : null,
        jsx('div', { className: 'hs-muted hs-small', children: `${dec.reason} The change is written to the audit log.` }),
        s.error ? jsx(ErrorBox, { error: s.error }) : null,
      ],
    }),
  });
}

function PreviewBody({ q, args }) {
  if (!q.res) return jsx(Spinner, { label: 'Asking the server for a preview…' });
  if (!q.res.ok) {
    return jsxs('div', {
      className: 'hs-stack',
      children: [
        jsx(ErrorBox, { error: q.res.error }),
        jsx('div', { className: 'hs-muted hs-small', children: 'Arguments that will be sent:' }),
        jsx('pre', { className: 'hs-whatif', children: pretty(args) }),
      ],
    });
  }
  const p = q.res.data || {};
  const lines = [p.summary, ...list(p.changes).map((c) => (typeof c === 'string' ? c : pretty(c)))].filter(Boolean);
  const blocks = [];
  if (lines.length) blocks.push(jsx('pre', { className: 'hs-whatif', children: lines.join('\n') }, 'changes'));
  list(p.warnings).forEach((w, i) => blocks.push(jsx('div', { className: 'hs-small', style: { color: 'var(--ui-yellow)' }, children: String(w) }, `warn-${i}`)));
  if (p.current !== undefined && p.current !== null) {
    blocks.push(jsx('div', { className: 'hs-muted hs-small', children: 'Current state' }, 'cur-l'));
    blocks.push(jsx('pre', { className: 'hs-whatif', children: pretty(p.current) }, 'cur'));
  }
  if (p.details !== undefined && p.details !== null) {
    blocks.push(jsx('div', { className: 'hs-muted hs-small', children: 'Arguments' }, 'det-l'));
    blocks.push(jsx('pre', { className: 'hs-whatif', children: pretty(p.details) }, 'det'));
  }
  if (!blocks.length) blocks.push(jsx('pre', { className: 'hs-whatif', children: pretty(args) }, 'args'));
  return jsx('div', { className: 'hs-stack', children: blocks });
}

function HighRiskDialog({ seq, o, dec, opts }) {
  const pv = useApi(KEY.preview(o, seq), () => api.preview(o), { staleTime: Infinity });
  const [typed, setTyped] = useState('');
  // Only destructive changes (delete, overwrite, raw PowerShell) make the user type the name;
  // other high-risk changes are approved from the preview with one click.
  const needType = dec.type_to_confirm === true;
  const expected = String(dec.confirm_name || '');
  const match = !needType || (expected !== '' && typed.trim().toLowerCase() === expected.trim().toLowerCase());
  const s = useSubmit(seq, o, needType ? { confirm: true, confirm_name: typed.trim() } : { confirm: true }, opts);
  const title = opts.title || 'High-risk change';
  return jsx(Modal, {
    seq,
    title,
    tier: 'H',
    opName: o.name,
    wide: true,
    footer: [
      jsx(Btn, { onClick: () => closeDialog(seq), disabled: s.busy, children: 'Cancel' }, 'cancel'),
      jsx(Btn, {
        kind: 'solid-danger',
        onClick: () => { if (match) s.submit(); },
        disabled: !match || s.busy,
        children: s.busy ? 'Working…' : opts.confirmLabel || title,
      }, 'ok'),
    ],
    children: jsxs('div', {
      className: 'hs-stack',
      children: [
        opts.body ? jsx('p', { className: 'hs-p', children: opts.body }) : null,
        jsx('div', { className: 'hs-muted hs-small', children: `${dec.reason} Preview from the server (-Preview). Nothing has changed yet.` }),
        jsx(PreviewBody, { q: pv, args: o.args }),
        needType ? jsxs('label', {
          className: 'hs-field',
          children: [
            jsxs('span', { children: ['Type ', jsx('b', { className: 'hs-mono', style: { color: 'var(--ui-text-primary)' }, children: expected }), ' to confirm'] }),
            jsx(TextInput, { value: typed, onChange: setTyped, mono: true, autoFocus: true, onEnter: () => { if (match && !s.busy) s.submit(); } }),
          ],
        }) : null,
        s.error ? jsx(ErrorBox, { error: s.error }) : null,
      ],
    }),
  });
}

function BlockedDialog({ seq, o, dec, opts }) {
  return jsx(Modal, {
    seq,
    title: opts.title || 'Blocked by policy',
    tier: dec.tier,
    opName: o.name,
    footer: [closeButton(seq)],
    children: jsxs('div', {
      className: 'hs-stack',
      children: [
        jsx(Callout, {
          tone: 'red',
          icon: Ico('shield'),
          children: jsxs('div', { children: [jsx('b', { children: 'Blocked. ' }), dec.reason] }),
        }),
        dec.target ? jsxs('div', { className: 'hs-muted hs-small', children: ['Target: ', jsx('span', { className: 'hs-mono', children: dec.target })] }) : null,
        jsx('div', { className: 'hs-muted hs-small', children: 'The hermes-sysadmin safety policy blocks this change; it cannot be approved from the dashboard.' }),
      ],
    }),
  });
}

function ErrorDialog({ seq, title, error }) {
  return jsx(Modal, { seq, title: title || 'Something went wrong', footer: [closeButton(seq)], children: jsx(ErrorBox, { error }) });
}

function InfoDialog({ seq, title, wide, children }) {
  return jsx(Modal, { seq, title, wide, footer: [closeButton(seq)], children });
}

// One-time secret reveal. The secret only lives in this dialog's props inside $dialog;
// closing the dialog drops it, and nothing else keeps a copy.
function SecretDialog({ seq, title, who, secret, note, details }) {
  const [copied, setCopied] = useState(false);
  const copy = async () => {
    setCopied(await copyText(secret));
  };
  return jsx(Modal, {
    seq,
    title,
    footer: [
      jsx(Btn, { onClick: copy, children: copied ? 'Copied' : 'Copy' }, 'copy'),
      jsx(Btn, { kind: 'primary', onClick: () => closeDialog(seq), children: 'Done' }, 'done'),
    ],
    children: jsxs('div', {
      className: 'hs-stack',
      children: [
        jsxs('p', { className: 'hs-p', children: ['New password for ', jsx('b', { className: 'hs-mono', children: who }), ':'] }),
        jsx('div', { className: 'hs-whatif hs-secret', children: secret }),
        jsx('p', { className: 'hs-muted hs-small hs-p', children: `Copy it now. It won't be shown again and is never written to the audit log.${note ? ` ${note}` : ''}` }),
        details ? jsx('div', { className: 'hs-muted hs-small', children: details }) : null,
      ],
    }),
  });
}

