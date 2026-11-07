// ============================================================================
// §9a OVERVIEW: NEEDS ATTENTION + ASK HERMES
// Pure finding logic first (attentionItems, healthScore: unit-tested), then the hero card.
// ============================================================================
const SEVERITY_WEIGHT = { danger: 12, warning: 5 };
const SEVERITY_RANK = { danger: 0, warning: 1 };
const READ_ONLY_ASK = 'Investigate with the hermes-sysadmin read tools and catalog first; do not change anything until you have shown me a plan and I approve it.';

function plainCount(n, one, many) {
  return `${n} ${n === 1 ? one : many || `${one}s`}`;
}

// One finding per problem the overview can see. Each carries where to look in the UI (go) and a
// prompt that hands the problem to the agent (ask). Severity: danger (act now) or warning (look soon).
function attentionItems({ kpis, fleet, dcs, alerts, diskPct }) {
  const k = kpis || {};
  const s = fleet || null;
  const out = [];
  const add = (id, severity, title, detail, go, ask) => out.push({ id, severity, title, detail, go, ask });
  const n = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : 0);

  const dcItems = (dcs && Array.isArray(dcs.items) ? dcs.items : []);
  const dcDown = dcItems.filter((d) => d.reachable === false || d.status === 'bad');
  const replFail = dcItems.filter((d) => n((d.replication || {}).failures) > 0);
  if (dcDown.length) {
    add('dc-down', 'danger', `${plainCount(dcDown.length, 'domain controller')} unhealthy`, dcDown.map((d) => d.name).join(', '), { tab: 'overview' },
      `Domain controller(s) ${dcDown.map((d) => d.name).join(', ')} look unhealthy. Use the domain-health-check skill to find out why. ${READ_ONLY_ASK}`);
  }
  if (replFail.length) {
    add('repl', 'danger', 'AD replication failures', replFail.map((d) => `${d.name}: ${n(d.replication.failures)}`).join(', '), { tab: 'overview' },
      `AD replication is failing on ${replFail.map((d) => d.name).join(', ')}. Use the domain-health-check skill to diagnose it. ${READ_ONLY_ASK}`);
  }
  if (n(alerts)) {
    add('alerts', 'danger', plainCount(n(alerts), 'open monitoring alert'), 'raised by scheduled monitoring', { tab: 'overview', scroll: 'monitoring' },
      `Monitoring has ${plainCount(n(alerts), 'open alert')}. Use the fleet-health-check skill to triage them and tell me what needs attention first. ${READ_ONLY_ASK}`);
  }
  if (n(k.backups_bad)) {
    add('backups', 'danger', `${plainCount(n(k.backups_bad), 'server')} without a recent backup`, `${n(k.backups_ok)} of ${n(k.backups_total)} backups OK`, { tab: 'backups' },
      `${plainCount(n(k.backups_bad), 'server')} have no recent Windows Server Backup. Use the backup-recovery-guide skill to check backup status and versions and explain the risk. ${READ_ONLY_ASK}`);
  }
  if (s) {
    const online = n(s.online);
    const pct = online > 0 ? Math.round((100 * n(s.patch_compliant)) / online) : null;
    if (pct !== null && pct < 90) {
      add('patch', pct < 70 ? 'danger' : 'warning', `Patch compliance ${pct}%`, `${online - n(s.patch_compliant)} of ${online} online computers not patched in 35 days`, { tab: 'fleet', fleet: { filter: 'patch_old' } },
        `Only ${pct}% of online computers are patched within 35 days. Use the fleet-health-check skill to list the worst offenders and why they are behind (Windows Update errors, pending reboots, offline). ${READ_ONLY_ASK}`);
    }
    if (n(s.defender_off)) {
      add('defender', 'danger', `Defender off on ${plainCount(n(s.defender_off), 'computer')}`, 'real-time protection disabled', { tab: 'fleet', fleet: { filter: 'defender_off' } },
        `Microsoft Defender real-time protection is off on ${plainCount(n(s.defender_off), 'computer')}. Use the endpoint-triage skill to confirm on each and find out whether another AV replaced it. ${READ_ONLY_ASK}`);
    }
    if (n(s.bitlocker_off)) {
      add('bitlocker', 'warning', `BitLocker off on ${plainCount(n(s.bitlocker_off), 'computer')}`, 'system drive not encrypted', { tab: 'fleet', fleet: { filter: 'bitlocker_off' } },
        `BitLocker is off on ${plainCount(n(s.bitlocker_off), 'computer')}. Find out which are laptops, whether the TPM is ready, and what it would take to enable it. ${READ_ONLY_ASK}`);
    }
    if (n(s.rdp_no_nla)) {
      add('nla', 'warning', `RDP without NLA on ${plainCount(n(s.rdp_no_nla), 'computer')}`, 'Network Level Authentication not required', { tab: 'fleet', fleet: { filter: 'rdp_no_nla' } },
        `Remote Desktop is enabled without Network Level Authentication on ${plainCount(n(s.rdp_no_nla), 'computer')}. Use the remote-assist skill to confirm and preview requiring NLA with the catalog's set_nla entry. ${READ_ONLY_ASK}`);
    }
    if (n(s.pending_reboot)) {
      add('reboot', 'warning', `${plainCount(n(s.pending_reboot), 'computer')} waiting to reboot`, 'updates or installs need a restart', { tab: 'fleet', fleet: { filter: 'reboot' } },
        `${plainCount(n(s.pending_reboot), 'computer')} have a pending reboot. Group them by why (Windows Update, CBS, file rename) and suggest a reboot plan that avoids people's working hours. ${READ_ONLY_ASK}`);
    }
    const lowDisk = n(s.low_disk_count !== undefined ? s.low_disk_count : null);
    if (lowDisk) {
      add('disk', 'danger', `${plainCount(lowDisk, 'computer')} low on disk`, `under ${diskPct || 10}% free on C:`, { tab: 'fleet', fleet: { filter: 'low_disk' } },
        `${plainCount(lowDisk, 'computer')} have under ${diskPct || 10}% free on C:. Use the endpoint-triage skill to find what is using the space and preview the catalog's clear_temp entry where it helps. ${READ_ONLY_ASK}`);
    }
  }
  if (n(k.gpos_needing_attention)) {
    add('gpo', 'warning', `${plainCount(n(k.gpos_needing_attention), 'GPO')} need attention`, `of ${n(k.gpos)} Group Policy objects`, { tab: 'gpo' },
      `${plainCount(n(k.gpos_needing_attention), 'Group Policy object')} need attention (unlinked, empty or inconsistent). Explain each problem and what you would do about it. ${READ_ONLY_ASK}`);
  }
  if (n(k.users_locked)) {
    add('locked', 'warning', `${plainCount(n(k.users_locked), 'user')} locked out`, 'can not sign in right now', { tab: 'users', users: { status: 'locked' } },
      `${plainCount(n(k.users_locked), 'user')} are locked out. Use the lockout-triage skill to find the lockout source for each before anything is unlocked. ${READ_ONLY_ASK}`);
  }
  if (n(k.computers_stale)) {
    add('stale-computers', 'warning', `${plainCount(n(k.computers_stale), 'stale computer account')}`, 'no recent logon to the domain', { tab: 'fleet', fleet: { filter: 'offline' } },
      `There are ${plainCount(n(k.computers_stale), 'stale computer account')} in AD. List them with last logon and OU, and recommend which are safe to disable. ${READ_ONLY_ASK}`);
  }
  if (n(k.users_never_expire) && n(k.users) && n(k.users_never_expire) / n(k.users) >= 0.25) {
    add('never-expire', 'warning', `${plainCount(n(k.users_never_expire), 'account')} with non-expiring passwords`, `${Math.round((100 * n(k.users_never_expire)) / n(k.users))}% of user accounts`, { tab: 'users' },
      `${plainCount(n(k.users_never_expire), 'user account')} have passwords that never expire. Use the access-review skill to separate service accounts from people and recommend a fix. ${READ_ONLY_ASK}`);
  }
  return out.sort((a, b) => SEVERITY_RANK[a.severity] - SEVERITY_RANK[b.severity]);
}

// 100 minus a fixed penalty per finding; a coarse "how worried should I be" number, never below 0.
function healthScore(items) {
  const penalty = (items || []).reduce((sum, i) => sum + (SEVERITY_WEIGHT[i.severity] || 0), 0);
  return Math.max(0, 100 - penalty);
}

function scoreTone(score) {
  return score >= 85 ? 'success' : score >= 60 ? 'warning' : 'danger';
}

const ASK_HEALTH_CHECK =
  'Run a fleet and domain health check with the fleet-health-check and domain-health-check skills. Summarize the top problems by risk, with the evidence for each. ' + READ_ONLY_ASK;

// Hand a prompt to the agent: open a new chat and put the prompt in its composer for the user to review
// and send. Falls back to the clipboard on desktops without the composer API.
async function askHermes(prompt) {
  const composer = host && host.composer;
  if (!composer || typeof composer.setDraft !== 'function' || typeof host.newChat !== 'function') {
    const ok = await writeClipboardText(prompt).then(() => true, () => false);
    host.notify({ kind: ok ? 'info' : 'error', message: ok ? 'Prompt copied: paste it into a new chat.' : 'Could not open a chat for this prompt.' });
    return false;
  }
  host.newChat();
  for (let i = 0; i < 25; i += 1) {
    await new Promise((r) => setTimeout(r, 160));
    let placed = false;
    try {
      placed = await composer.setDraft(null, prompt);
    } catch (e) {
      placed = false;
    }
    if (placed) {
      host.notify({ kind: 'info', message: 'Prompt ready in a new chat: review it, then press Enter.' });
      return true;
    }
  }
  const ok = await writeClipboardText(prompt).then(() => true, () => false);
  host.notify({ kind: ok ? 'info' : 'error', message: ok ? 'New chat opened; the prompt is on your clipboard.' : 'Could not place the prompt in the chat.' });
  return false;
}

function AskButton({ prompt, label, primary }) {
  return jsx('button', {
    type: 'button',
    className: `hs-ask${primary ? ' primary' : ''}`,
    title: 'Open a new chat with this prompt ready to send',
    onClick: (e) => {
      e.stopPropagation();
      askHermes(prompt);
    },
    children: [jsx('span', { className: 'hs-ask-spark', 'aria-hidden': 'true', children: '✦' }, 's'), label || 'Ask Hermes'],
  });
}

function ScoreRing({ score, size = 112 }) {
  const r = size / 2 - 7;
  const c = 2 * Math.PI * r;
  const tone = scoreTone(score);
  return jsx('figure', {
    className: `hs-score ${tone}`,
    role: 'img',
    'aria-label': `Health score ${score} of 100`,
    style: { width: size, height: size },
    children: [
      jsx('svg', {
        width: size,
        height: size,
        viewBox: `0 0 ${size} ${size}`,
        'aria-hidden': 'true',
        children: [
          jsx('circle', { cx: size / 2, cy: size / 2, r, className: 'hs-score-track' }, 't'),
          jsx('circle', {
            cx: size / 2,
            cy: size / 2,
            r,
            className: 'hs-score-arc',
            strokeDasharray: `${(c * score) / 100} ${c}`,
            transform: `rotate(-90 ${size / 2} ${size / 2})`,
          }, 'a'),
        ],
      }, 'svg'),
      jsx('div', { className: 'hs-score-text', children: [jsx('b', { children: String(score) }, 'v'), jsx('span', { children: 'health' }, 'l')] }, 'txt'),
    ],
  });
}

function goAttention(item, alertsRef) {
  const g = item.go || {};
  if (g.scroll === 'monitoring' && alertsRef && alertsRef.current) {
    alertsRef.current.scrollIntoView({ behavior: 'smooth', block: 'start' });
    return;
  }
  const { tab, ...patch } = g;
  if (tab && tab !== 'overview') goTab(tab, patch);
}

function AttentionCard({ data, fleet, monitoring, alertsRef }) {
  const fleetData = fleet.res && fleet.res.ok ? fleet.res.data || {} : null;
  const summary = fleetData ? { ...(fleetData.summary || {}) } : null;
  const diskPct = diskThreshold(monitoring);
  if (summary && fleetData) {
    summary.low_disk_count = list(fleetData.items).filter((i) => i.online && typeof i.c_free_pct === 'number' && i.c_free_pct < diskPct).length;
  }
  const alerts = monitoring.res && monitoring.res.ok ? list((monitoring.res.data || {}).open_alerts).length : 0;
  const items = attentionItems({ kpis: data.kpis, fleet: summary, dcs: data.dcs, alerts, diskPct });
  const score = healthScore(items);
  const danger = items.filter((i) => i.severity === 'danger').length;
  const pendingFleet = !fleet.res;
  return jsxs('section', {
    className: 'hs-hero',
    children: [
      jsxs('div', {
        className: 'hs-hero-side',
        children: [
          jsx(ScoreRing, { score }),
          jsxs('div', {
            className: 'hs-hero-copy',
            children: [
              jsx('div', { className: 'hs-hero-title', children: items.length ? `${plainCount(items.length, 'thing')} need${items.length === 1 ? 's' : ''} attention` : 'All clear' }),
              jsx('div', {
                className: 'hs-muted hs-small',
                children: pendingFleet ? 'Fleet inventory still collecting…' : danger ? `${danger} urgent · ${items.length - danger} to review` : items.length ? 'Nothing urgent' : 'No problems found in the latest data',
              }),
              jsx(AskButton, { prompt: ASK_HEALTH_CHECK, label: 'Ask Hermes for a health check', primary: true }),
            ],
          }),
        ],
      }),
      jsx('ol', {
        className: 'hs-attn',
        children: items.length
          ? items.slice(0, 7).map((i) =>
              jsxs('li', {
                className: `hs-attn-row ${i.severity}`,
                children: [
                  jsx('span', { className: 'hs-attn-dot', 'aria-hidden': 'true' }),
                  jsxs('button', {
                    type: 'button',
                    className: 'hs-attn-main',
                    onClick: () => goAttention(i, alertsRef),
                    children: [jsx('b', { children: i.title }, 't'), jsx('span', { className: 'hs-muted hs-small', children: i.detail }, 'd')],
                  }),
                  jsx(AskButton, { prompt: i.ask }),
                ],
              }, i.id),
            )
          : jsx('li', { className: 'hs-attn-empty hs-muted', children: pendingFleet ? 'Checking the fleet…' : 'Domain controllers, backups, patching and security posture all look fine.' }),
      }),
    ],
  });
}
