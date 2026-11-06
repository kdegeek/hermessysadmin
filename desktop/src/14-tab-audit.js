// ============================================================================
// §14 TAB: AUDIT
// ============================================================================
const AUDIT_COLUMNS = ['id', 'ts', 'actor', 'session', 'tool', 'target', 'tier', 'decision', 'result', 'params'];

function auditMatches(a, f) {
  if (f.denied && !/^(denied|blocked)/.test(String(a.decision || ''))) return false;
  if (f.failed && !String(a.result || '').startsWith('failed')) return false;
  if (!f.text) return true;
  const t = f.text.toLowerCase();
  return [a.tool, a.target, a.actor, a.decision, a.result].some((v) => String(v || '').toLowerCase().includes(t));
}

async function exportAuditCsv(rows) {
  const lines = [AUDIT_COLUMNS.join(',')].concat(rows.map((a) => AUDIT_COLUMNS.map((c) => csvCell(a[c])).join(',')));
  const stamp = new Date().toISOString().slice(0, 10);
  const saved = await saveText(`hermes-sysadmin-audit-${stamp}.csv`, `${lines.join('\n')}\n`);
  host.notify({ kind: saved.ok ? 'info' : 'error', message: savedMessage(`${plural(rows.length, 'audit row')}`, saved) });
}

function AuditRowDialog({ seq, row }) {
  let params = row.params;
  if (typeof params === 'string') {
    try {
      params = JSON.parse(params);
    } catch (_) {
      // keep the raw text
    }
  }
  return jsx(InfoDialog, {
    seq,
    title: `${row.tool} · ${fmtDate(row.ts)}`,
    wide: true,
    children: jsxs('div', {
      className: 'hs-stack',
      children: [
        jsx(KV, {
          rows: [
            ['Actor', row.actor],
            row.session ? ['Session', jsx('span', { className: 'hs-mono hs-tiny', children: row.session })] : null,
            ['Tier', jsx(TierTag, { tier: row.tier })],
            ['Target', row.target || '—'],
            ['Decision', row.decision],
            ['Result', row.result],
          ],
        }),
        jsx('div', { className: 'hs-label', children: 'Parameters (secrets redacted)' }),
        jsx('div', { className: 'hs-whatif', children: typeof params === 'string' ? params : pretty(params) }),
      ],
    }),
  });
}

function AuditTab() {
  const [actor, setActor] = useState('');
  const [denied, setDenied] = useState(false);
  const [failed, setFailed] = useState(false);
  const [text, setText] = useState('');
  const query = actor ? { limit: 500, actor } : { limit: 500 };
  const q = useApi(KEY.audit(query), () => api.audit(query), { refetchInterval: POLL.audit });
  const items = q.res && q.res.ok ? list(q.res.data.items) : [];
  const rows = items.filter((a) => auditMatches(a, { text: text.trim(), denied, failed }));
  return jsxs('div', {
    children: [
      jsxs('div', {
        className: 'hs-toolbar',
        children: [
          jsx(SearchBox, { value: text, onChange: setText, placeholder: 'Search tool, target, actor…' }),
          jsx(Chip, { on: actor === 'agent', onClick: () => setActor(actor === 'agent' ? '' : 'agent'), children: 'Agent' }),
          jsx(Chip, { on: actor === 'dashboard', onClick: () => setActor(actor === 'dashboard' ? '' : 'dashboard'), children: 'Dashboard' }),
          jsx(Chip, { on: denied, onClick: () => setDenied(!denied), children: 'Denied / blocked' }),
          jsx(Chip, { on: failed, onClick: () => setFailed(!failed), children: 'Failed' }),
          jsx('span', { className: 'hs-grow' }),
          jsx(Btn, { disabled: !rows.length, onClick: () => exportAuditCsv(rows), children: 'Export CSV' }),
        ],
      }),
      jsx(Pending, {
        q,
        label: 'Reading the audit log…',
        children: () =>
          jsxs('div', {
            children: [
              jsx(Card, {
                children: jsx(Table, {
                  head: ['Time', 'Actor', 'Tier', 'Action', 'Target', 'Decision / result'],
                  children: rows.length
                    ? rows.map((a) =>
                        jsxs('tr', {
                          className: 'click',
                          onClick: () => openDialog(AuditRowDialog, { row: a }),
                          children: [
                            jsx('td', { className: 'hs-mono hs-muted hs-nowrap', children: fmtDate(a.ts) }),
                            jsx('td', { children: a.actor }),
                            jsx('td', { children: jsx(TierTag, { tier: a.tier }) }),
                            jsx('td', { className: 'hs-mono', children: a.tool }),
                            jsx('td', { children: a.target }),
                            jsx('td', { children: jsx(AuditDecision, { row: a }) }),
                          ],
                        }, a.id),
                      )
                    : jsx(EmptyRow, { cols: 6, text: 'No audit rows match' }),
                }),
              }),
              jsx('p', {
                className: 'hs-muted hs-small',
                children: `Showing ${num(rows.length)} of the latest ${num(items.length)} rows. Passwords and secret parameters are redacted before storage. Stored locally in the plugin's SQLite database.`,
              }),
            ],
          }),
      }),
    ],
  });
}

