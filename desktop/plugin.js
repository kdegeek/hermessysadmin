// ============================================================================
// §1 IMPORTS AND CONSTANTS
// ============================================================================
import { useEffect, useRef, useState } from 'react';
import { jsx, jsxs } from 'react/jsx-runtime';
import {
  Button,
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  ErrorState,
  GlyphSpinner,
  PALETTE_AREA,
  ROUTES_AREA,
  SIDEBAR_NAV_AREA,
  STATUSBAR_AREAS,
  StatusDot,
  Switch,
  atom,
  host,
  queryClient,
  useQuery,
  useValue,
  writeClipboardText,
} from '@hermes/plugin-sdk';

const PLUGIN_ID = 'hermes-sysadmin';
const ROUTE = '/hermes-sysadmin';
const CHANGED_EVENT = 'plugin.hermes-sysadmin.changed';
// Agent plugins with a config_schema get an automatic Settings page at this route.
const SETTINGS_HREF = '/settings?tab=plugins&agent=hermes-sysadmin';
const OP_TIMEOUT_MS = 120000;
const POLL = { health: 60000, overview: 60000, list: 60000, sessions: 30000, backups: 60000, job: 5000, audit: 30000 };

// The PluginContext handed to register(); every component runs after register().
let CTX = null;

// ============================================================================
// §2 CSS (every colour comes from the host's --ui-* theme variables)
// ============================================================================
const CSS = `
.hs-root{position:relative;height:100%;min-height:0;display:flex;flex-direction:column;color:var(--ui-text-primary);font-size:13px;line-height:1.45}
.hs-root *,.hs-modal *{box-sizing:border-box}
.hs-scroll{flex:1;min-height:0;overflow:auto}
.hs-page{padding:18px 22px 40px;max-width:1280px}
.hs-head{display:flex;align-items:center;gap:12px;margin-bottom:12px;flex-wrap:wrap}
.hs-head h1{font-size:17px;margin:0;font-weight:600}
.hs-domain{color:var(--ui-text-tertiary)}
.hs-grow{flex:1}
.hs-tabs{display:flex;gap:2px;border-bottom:1px solid var(--ui-stroke-secondary);margin-bottom:16px;overflow-x:auto}
.hs-tab{padding:7px 12px;border:0;background:none;color:var(--ui-text-tertiary);cursor:pointer;border-bottom:2px solid transparent;margin-bottom:-1px;white-space:nowrap;font:inherit}
.hs-tab:hover{color:var(--ui-text-primary)}
.hs-tab.on{color:var(--ui-text-primary);border-bottom-color:var(--ui-accent)}
.hs-tab .hs-n{font-size:11px;margin-left:4px;padding:0 5px;border-radius:8px;background:var(--ui-bg-card);color:var(--ui-text-tertiary)}
.hs-ghost{border:0;background:none;color:var(--ui-text-tertiary);cursor:pointer;padding:2px 6px;border-radius:4px;font:inherit}
.hs-ghost:hover{background:var(--ui-row-hover-background);color:var(--ui-text-primary)}
.hs-ghost.hs-x{padding:0 2px}
.hs-danger{color:var(--ui-red)}
.hs-badge{display:inline-flex;align-items:center;gap:4px;font-size:11px;padding:1px 7px;border-radius:10px;background:var(--ui-bg-card);color:var(--ui-text-secondary);border:1px solid var(--ui-stroke-tertiary);white-space:nowrap}
.hs-badge.red{color:var(--ui-red);border-color:color-mix(in srgb,var(--ui-red) 30%,transparent);background:color-mix(in srgb,var(--ui-red) 8%,transparent)}
.hs-badge.yellow{color:var(--ui-yellow);border-color:color-mix(in srgb,var(--ui-yellow) 30%,transparent);background:color-mix(in srgb,var(--ui-yellow) 8%,transparent)}
.hs-badge.green{color:var(--ui-green);border-color:color-mix(in srgb,var(--ui-green) 30%,transparent);background:color-mix(in srgb,var(--ui-green) 8%,transparent)}
.hs-badge.accent{color:var(--ui-accent);border-color:color-mix(in srgb,var(--ui-accent) 30%,transparent);background:color-mix(in srgb,var(--ui-accent) 8%,transparent)}
.hs-text-red{color:var(--ui-red)}
.hs-text-yellow{color:var(--ui-yellow)}
.hs-text-green{color:var(--ui-green)}
.hs-kpis{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:10px;margin-bottom:18px}
.hs-kpi{background:var(--ui-bg-card);border:1px solid var(--ui-stroke-tertiary);border-radius:8px;padding:10px 12px;cursor:pointer;text-align:left;font:inherit;color:inherit}
.hs-kpi:hover{border-color:var(--ui-stroke-secondary)}
.hs-kpi .hs-v{font-size:22px;font-weight:600;font-variant-numeric:tabular-nums}
.hs-kpi .hs-l{color:var(--ui-text-tertiary);font-size:12px}
.hs-kpi .hs-s{font-size:11.5px;margin-top:2px}
.hs-grid2{display:grid;grid-template-columns:1.4fr 1fr;gap:16px;align-items:start}
.hs-grid2.hs-gpo{grid-template-columns:1.3fr 1fr}
@media (max-width:900px){.hs-grid2,.hs-grid2.hs-gpo{grid-template-columns:1fr}}
.hs-card{background:var(--ui-bg-card);border:1px solid var(--ui-stroke-tertiary);border-radius:8px;overflow:hidden}
.hs-card h3{margin:0;font-size:12.5px;font-weight:600;padding:9px 12px;border-bottom:1px solid var(--ui-stroke-tertiary);display:flex;align-items:center;gap:8px}
.hs-card h3 .hs-sub{font-weight:400;color:var(--ui-text-tertiary)}
.hs-card-body{padding:12px;display:grid;gap:12px}
.hs-table{width:100%;border-collapse:collapse}
.hs-table th{font-weight:500;color:var(--ui-text-tertiary);font-size:11.5px;text-align:left;padding:6px 12px;border-bottom:1px solid var(--ui-stroke-tertiary);white-space:nowrap}
.hs-table td{padding:7px 12px;border-bottom:1px solid var(--ui-stroke-tertiary);vertical-align:middle}
.hs-table tr:last-child td{border-bottom:0}
.hs-table tbody tr.click{cursor:pointer}
.hs-table tbody tr.click:hover{background:var(--ui-row-hover-background)}
.hs-table tbody tr.sel{background:var(--ui-row-active-background)}
.hs-table td.hs-empty-row{text-align:center;padding:24px;color:var(--ui-text-tertiary)}
.hs-nowrap{white-space:nowrap}
.hs-mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px}
.hs-muted{color:var(--ui-text-tertiary)}
.hs-small{font-size:12px}
.hs-tiny{font-size:11px}
.hs-p{margin:0 0 8px}
.hs-stack{display:grid;gap:10px}
.hs-toolbar{display:flex;gap:8px;align-items:center;margin-bottom:10px;flex-wrap:wrap}
.hs-search{flex:0 1 300px;border:1px solid var(--ui-stroke-secondary);background:var(--ui-bg-input);border-radius:6px;padding:5px 10px;color:var(--ui-text-primary);font:inherit}
.hs-chip{border:1px solid var(--ui-stroke-secondary);background:none;border-radius:12px;padding:2px 10px;font-size:12px;cursor:pointer;color:var(--ui-text-secondary);font-family:inherit}
.hs-chip.on{background:var(--ui-row-active-background);border-color:color-mix(in srgb,var(--ui-accent) 40%,transparent);color:var(--ui-text-primary)}
.hs-seg{display:inline-flex;border:1px solid var(--ui-stroke-secondary);border-radius:6px;overflow:hidden;align-self:flex-start}
.hs-seg button{border:0;background:none;padding:3px 10px;cursor:pointer;color:var(--ui-text-tertiary);font:inherit}
.hs-seg button.on{background:var(--ui-row-active-background);color:var(--ui-text-primary)}
.hs-loading{display:flex;align-items:center;gap:8px;color:var(--ui-text-tertiary);padding:16px 4px}
.hs-drawer{position:absolute;top:0;right:0;bottom:0;width:420px;max-width:100%;background:var(--ui-bg-elevated);border-left:1px solid var(--ui-stroke-secondary);box-shadow:-12px 0 30px color-mix(in srgb,var(--ui-base) 14%,transparent);overflow:auto;z-index:20}
.hs-dh{display:flex;align-items:center;gap:10px;padding:14px 16px;border-bottom:1px solid var(--ui-stroke-tertiary);position:sticky;top:0;background:var(--ui-bg-elevated);z-index:1}
.hs-avatar{width:34px;height:34px;border-radius:50%;background:color-mix(in srgb,var(--ui-accent) 20%,transparent);display:grid;place-items:center;font-weight:600;color:var(--ui-accent);flex:none}
.hs-sec{padding:12px 16px;border-bottom:1px solid var(--ui-stroke-tertiary)}
.hs-sec h4,.hs-label{margin:0 0 8px;font-size:11.5px;text-transform:uppercase;letter-spacing:.04em;color:var(--ui-text-quaternary);font-weight:500}
.hs-kv{display:grid;grid-template-columns:130px 1fr;gap:4px 10px;font-size:12.5px}
.hs-kv-row{display:contents}
.hs-kv .hs-k{color:var(--ui-text-tertiary)}
.hs-kv>.hs-kv-row>span:last-child{min-width:0;overflow-wrap:anywhere}
.hs-actions{display:flex;flex-wrap:wrap;gap:6px;align-items:center}
.hs-row{display:flex;gap:8px;align-items:center;margin-bottom:6px}
.hs-callout{border-radius:6px;padding:8px 10px;font-size:12.5px;display:flex;gap:8px;align-items:flex-start}
.hs-callout.red{background:color-mix(in srgb,var(--ui-red) 9%,transparent);border:1px solid color-mix(in srgb,var(--ui-red) 25%,transparent)}
.hs-callout.yellow{background:color-mix(in srgb,var(--ui-yellow) 9%,transparent);border:1px solid color-mix(in srgb,var(--ui-yellow) 25%,transparent)}
.hs-callout.accent{background:color-mix(in srgb,var(--ui-accent) 8%,transparent);border:1px solid color-mix(in srgb,var(--ui-accent) 25%,transparent)}
.hs-modal{width:480px;max-width:calc(100vw - 32px)}
.hs-modal.hs-modal-wide{width:680px;max-width:min(680px,calc(100vw - 32px)) !important}
.hs-modal-sub{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
.hs-modal-body{display:grid;gap:10px;font-size:13px;color:var(--ui-text-primary);max-height:60vh;overflow:auto}
.hs-whatif{background:var(--ui-bg-chrome);border:1px solid var(--ui-stroke-tertiary);border-radius:6px;padding:8px 10px;font-family:ui-monospace,Menlo,monospace;font-size:11.5px;white-space:pre-wrap;margin:0;color:var(--ui-text-secondary);overflow-wrap:anywhere}
.hs-secret{font-size:15px;color:var(--ui-text-primary);text-align:center;letter-spacing:.06em;user-select:all}
.hs-input{width:100%;border:1px solid var(--ui-stroke-secondary);background:var(--ui-bg-input);border-radius:6px;padding:6px 10px;color:var(--ui-text-primary);font:inherit}
textarea.hs-input{min-height:64px;resize:vertical}
.hs-field{font-size:12px;color:var(--ui-text-tertiary);display:grid;gap:4px}
.hs-check{font-size:12.5px;color:var(--ui-text-secondary);display:flex;gap:6px;align-items:center;cursor:pointer}
.hs-two{display:grid;grid-template-columns:1fr 1fr;gap:10px}
.hs-tier{font-size:10.5px;font-weight:600;letter-spacing:.04em;padding:1px 6px;border-radius:4px;white-space:nowrap}
.hs-tier-R{background:var(--ui-bg-card);color:var(--ui-text-tertiary)}
.hs-tier-W{background:color-mix(in srgb,var(--ui-yellow) 14%,transparent);color:var(--ui-yellow)}
.hs-tier-H{background:color-mix(in srgb,var(--ui-red) 14%,transparent);color:var(--ui-red)}
.hs-tier-P{background:var(--ui-text-primary);color:var(--ui-bg-editor)}
.hs-hosts{display:grid;grid-template-columns:repeat(auto-fill,minmax(270px,1fr));gap:12px}
.hs-hcard{background:var(--ui-bg-card);border:1px solid var(--ui-stroke-tertiary);border-radius:8px;padding:12px}
.hs-hcard.bad{border-color:color-mix(in srgb,var(--ui-red) 40%,transparent)}
.hs-hcard.warn{border-color:color-mix(in srgb,var(--ui-yellow) 40%,transparent)}
.hs-hcard .hs-top{display:flex;align-items:center;gap:8px;margin-bottom:8px}
.hs-hcard .hs-top b{flex:1}
.hs-bar{height:6px;border-radius:3px;background:var(--ui-stroke-tertiary);overflow:hidden;margin:8px 0 4px}
.hs-bar i{display:block;height:100%;background:var(--ui-accent);transition:width .4s}
.hs-empty{max-width:480px;margin:60px auto;text-align:center}
.hs-empty .hs-big{font-size:34px;margin-bottom:8px}
.hs-empty h2{margin:0 0 6px;font-size:17px}
.hs-form{display:grid;gap:10px;text-align:left;margin-top:16px}
.hs-checklist{margin:0;padding-left:18px;color:var(--ui-text-secondary);font-size:12.5px;display:grid;gap:2px}
.hs-end{display:flex;gap:8px;justify-content:flex-end;flex-wrap:wrap}
.hs-radio{display:flex;gap:6px;align-items:center;font-size:12.5px;cursor:pointer}
`;

// ============================================================================
// §3 API CLIENT AND HOST HELPERS
// ============================================================================
// Every op the page touches is named here, as a literal: op('ad_user_unlock', {...}).
// tests/test_desktop.py checks each literal against sysadmin.registry.OPS.
function op(name, args) {
  return { name, args: args || {} };
}

function errorText(err) {
  const raw = String((err && err.message) || err || 'Unknown error');
  const start = raw.indexOf('{');
  if (start >= 0) {
    try {
      const parsed = JSON.parse(raw.slice(start));
      const detail = parsed && parsed.detail;
      return (detail && (detail.message || (typeof detail === 'string' ? detail : ''))) || (parsed && parsed.message) || raw;
    } catch (_) {
      return raw;
    }
  }
  return raw;
}

function queryString(q) {
  return Object.entries(q || {})
    .filter(([, v]) => v !== undefined && v !== null && v !== '')
    .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(String(v))}`)
    .join('&');
}

// The backend answers HTTP 200 with {ok, data} or {ok: false, error}; transport failures
// are folded into the same envelope so the UI has exactly one error path.
async function rest(path, opts) {
  try {
    const res = await CTX.rest(path, opts || {});
    if (res && typeof res === 'object' && typeof res.ok === 'boolean') {
      return res;
    }
    return {
      ok: false,
      error: {
        type: 'BadResponse',
        message: `Unexpected response from ${path}.`,
        hint: 'Update hermes-sysadmin so the Desktop page and its backend come from the same version.',
      },
    };
  } catch (err) {
    return {
      ok: false,
      error: {
        type: 'RequestFailed',
        message: errorText(err),
        hint: 'Check that hermes-sysadmin is in plugins.enabled in config.yaml and that the gateway was restarted after enabling it.',
      },
    };
  }
}

const api = {
  health: () => rest('/health', { timeoutMs: 45000 }),
  testConnection: () => rest('/test-connection', { method: 'POST', body: {}, timeoutMs: 60000 }),
  overview: () => rest('/overview', { timeoutMs: OP_TIMEOUT_MS }),
  audit: (q) => rest(`/audit?${queryString(q)}`, { timeoutMs: 30000 }),
  refresh: () => rest('/refresh', { method: 'POST', body: {} }),
  read: (o) => rest(`/ops/${o.name}`, { method: 'POST', body: { args: o.args }, timeoutMs: OP_TIMEOUT_MS }),
  decision: (o) => rest(`/ops/${o.name}/decision`, { method: 'POST', body: { args: o.args }, timeoutMs: 30000 }),
  preview: (o) => rest(`/ops/${o.name}/preview`, { method: 'POST', body: { args: o.args }, timeoutMs: OP_TIMEOUT_MS }),
  run: (o, extra) => rest(`/ops/${o.name}`, { method: 'POST', body: { args: o.args, ...(extra || {}) }, timeoutMs: OP_TIMEOUT_MS }),
};

async function copyText(text) {
  try {
    if (CTX && CTX.os && (await CTX.os.writeClipboard(text))) {
      return true;
    }
  } catch (_) {
    // fall through to the SDK clipboard helper
  }
  try {
    await writeClipboardText(text);
    return true;
  } catch (_) {
    return false;
  }
}

function joinPath(base, rel) {
  const sep = base.includes('\\') && !base.includes('/') ? '\\' : '/';
  return base.replace(/[\\/]+$/, '') + sep + String(rel).split('/').join(sep);
}

// Save text where the user can open it: the first folder the user granted this plugin
// (asking once with the app's picker), then reveal it in Finder/Explorer. The plugin's
// private 'data' folder has no path a file manager could show, so it is not used here.
// Falls back to the clipboard.
async function saveText(filename, text) {
  const files = CTX && CTX.files;
  if (files && typeof files.folders === 'function' && typeof files.writeText === 'function') {
    let folder = (await files.folders())[0] || null;
    if (!folder && typeof files.requestFolder === 'function') {
      const picked = await files.requestFolder();
      folder = picked && picked.ok ? picked.folder : null;
    }
    if (folder) {
      const written = await files.writeText(folder.id, filename, text);
      if (written && written.ok) {
        const path = joinPath(folder.path, written.path);
        const revealed = await CTX.os.revealPath(path);
        return { ok: true, how: revealed ? 'revealed' : 'saved', path };
      }
    }
  }
  return (await copyText(text)) ? { ok: true, how: 'copied', path: '' } : { ok: false, how: 'none', path: '' };
}

function savedMessage(label, saved) {
  if (saved.how === 'revealed') return `${label} saved to ${saved.path} and shown in your file manager.`;
  if (saved.how === 'saved') return `${label} saved to ${saved.path}.`;
  if (saved.how === 'copied') return `${label} copied to the clipboard (no folder was granted to save it in).`;
  return `${label} could not be saved or copied.`;
}

function safeName(name) {
  return String(name || 'file').replace(/[^A-Za-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '') || 'file';
}

// ============================================================================
// §4 FORMATTERS
// ============================================================================
const DAY_MS = 86400000;
const ROLE_SHORT = {
  PDCEmulator: 'PDC',
  RIDMaster: 'RID',
  InfrastructureMaster: 'Infra',
  SchemaMaster: 'Schema',
  DomainNamingMaster: 'Naming',
};
const GPO_STATUS = {
  AllSettingsEnabled: 'Enabled',
  AllSettingsDisabled: 'All settings disabled',
  UserSettingsDisabled: 'Computer settings only',
  ComputerSettingsDisabled: 'User settings only',
};

function list(v) {
  return Array.isArray(v) ? v : [];
}

function toDate(v) {
  if (v === null || v === undefined || v === '') return null;
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? null : d;
}

function num(v) {
  return typeof v === 'number' && Number.isFinite(v) ? v.toLocaleString() : '—';
}

function plural(n, word) {
  return `${n} ${word}${n === 1 ? '' : 's'}`;
}

function ago(v) {
  const d = toDate(v);
  if (!d) return '—';
  const s = Math.max(0, Math.round((Date.now() - d.getTime()) / 1000));
  if (s < 60) return `${s} s ago`;
  if (s < 3600) return `${Math.round(s / 60)} min ago`;
  if (s < 86400) return `${Math.round(s / 3600)} h ago`;
  return `${Math.round(s / 86400)} days ago`;
}

function daysUntil(v) {
  const d = toDate(v);
  return d ? (d.getTime() - Date.now()) / DAY_MS : null;
}

function until(v) {
  const days = daysUntil(v);
  if (days === null) return '—';
  if (days < 0) return 'expired';
  const n = Math.ceil(days);
  return n === 0 ? 'today' : `in ${plural(n, 'day')}`;
}

function fmtDate(v) {
  const d = toDate(v);
  return d ? d.toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }) : '—';
}

function fmtDay(v) {
  const d = toDate(v);
  return d ? d.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' }) : '—';
}

function fmtTime(v) {
  const d = toDate(v);
  if (!d) return '—';
  const today = new Date().toDateString() === d.toDateString();
  return today
    ? d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit', second: '2-digit' })
    : fmtDate(d);
}

function ageText(hours) {
  if (typeof hours !== 'number') return '—';
  return hours < 48 ? `${Math.round(hours)} h` : `${Math.round(hours / 24)} d`;
}

function skewText(s) {
  if (typeof s !== 'number') return '—';
  return `${s >= 0 ? '+' : ''}${s.toFixed(1)} s`;
}

function rdns(dn) {
  return String(dn || '').split(/,(?=\s*(?:OU|CN|DC)=)/i).map((p) => p.trim()).filter(Boolean);
}

function dnsOf(dn) {
  return rdns(dn).filter((p) => /^DC=/i.test(p)).map((p) => p.slice(3)).join('.');
}

// "OU=Finance,OU=Staff,DC=corp,DC=local" → "Staff/Finance"
function ouPath(dn) {
  const parts = rdns(dn);
  const ous = parts.filter((p) => /^OU=/i.test(p)).map((p) => p.slice(3));
  if (ous.length) return ous.reverse().join('/');
  const cn = parts.find((p) => /^CN=/i.test(p));
  return cn ? cn.slice(3) : String(dn || '—');
}

// The first RDN, or the DNS name for a domain root ("DC=corp,DC=local" → "corp.local").
function shortDn(dn) {
  const parts = rdns(dn);
  if (!parts.length) return '—';
  return /^DC=/i.test(parts[0]) ? dnsOf(dn) : parts[0];
}

function shortHost(h) {
  return String(h || '').split('.')[0];
}

function sameHost(a, b) {
  return shortHost(a).toLowerCase() === shortHost(b).toLowerCase();
}

function initials(name) {
  return String(name || '?').split(/\s+/).filter(Boolean).map((w) => w[0]).join('').slice(0, 2).toUpperCase();
}

function splitList(text) {
  return String(text || '').split(/[\n,;]+/).map((s) => s.trim()).filter(Boolean);
}

function pretty(v) {
  try {
    return JSON.stringify(v, null, 2);
  } catch (_) {
    return String(v);
  }
}

function csvCell(v) {
  const s = v === null || v === undefined ? '' : typeof v === 'object' ? JSON.stringify(v) : String(v);
  return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

function toneOf(status) {
  if (status === 'ok') return 'good';
  if (status === 'warn') return 'warn';
  if (status === 'bad') return 'bad';
  return 'muted';
}

function decisionTone(row) {
  const failed = String(row.result || '').startsWith('failed');
  if (/^(approved|confirmed|allowed)/.test(String(row.decision || ''))) return failed ? 'yellow' : 'green';
  return 'red';
}

// ============================================================================
// §5 QUERIES, STORES AND HOOKS
// ============================================================================
// React Query (the app's shared QueryClient) caches, dedupes and polls; the backend's
// change event invalidates everything under KEY.all (see §16).
const KEY = {
  all: [PLUGIN_ID],
  health: [PLUGIN_ID, 'health'],
  overview: [PLUGIN_ID, 'overview'],
  audit: (q) => [PLUGIN_ID, 'audit', q],
  op: (o) => [PLUGIN_ID, 'op', o.name, o.args],
  decision: (o) => [PLUGIN_ID, 'decision', o.name, o.args],
  preview: (o, seq) => [PLUGIN_ID, 'preview', o.name, o.args, seq],
};

function invalidateAll() {
  queryClient.invalidateQueries({ queryKey: KEY.all });
}

function useApi(key, fetcher, opts) {
  const o = opts || {};
  const enabled = o.enabled !== false;
  const q = useQuery({
    queryKey: key,
    queryFn: fetcher,
    enabled,
    refetchInterval: o.refetchInterval || false,
    staleTime: o.staleTime === undefined ? 10000 : o.staleTime,
    refetchOnWindowFocus: false,
  });
  return {
    res: q.data || null,
    loading: enabled && !q.data && q.isFetching,
    fetching: q.isFetching,
    updatedAt: q.dataUpdatedAt || 0,
    refetch: q.refetch,
  };
}

function useOp(o, opts) {
  return useApi(KEY.op(o), () => api.read(o), opts);
}

function useHealth() {
  return useApi(KEY.health, api.health, { refetchInterval: POLL.health });
}

function useOverview(enabled) {
  return useApi(KEY.overview, api.overview, { refetchInterval: POLL.overview, enabled });
}

function useDebounced(value, ms) {
  const [v, setV] = useState(value);
  useEffect(() => CTX.setTimeout(() => setV(value), ms), [value, ms]);
  return v;
}

function useTick(ms) {
  const [, setN] = useState(0);
  useEffect(() => CTX.setInterval(() => setN((n) => n + 1), ms), [ms]);
}

// Page state lives in atoms so palette commands can steer the page from outside React.
const $tab = atom('overview');
const $users = atom({ query: '', status: 'any', stale: false, expiring: false, privileged: false, limit: 200 });
const $rdpView = atom('sessions');
const $focusSearch = atom(0);
const $drawer = atom(null);
const $dialog = atom(null);
let dialogSeq = 0;

function openDialog(Component, props) {
  dialogSeq += 1;
  $dialog.set({ Component, props: props || {}, seq: dialogSeq });
  return dialogSeq;
}

// Closes only the dialog with this seq, so a form that hands off to another dialog
// (a password reveal, a high-risk preview) never closes its successor.
function closeDialog(seq) {
  const cur = $dialog.get();
  if (cur && (seq === undefined || cur.seq === seq)) {
    $dialog.set(null);
  }
}

function goTab(key, patch) {
  if (!TABS.some((t) => t.key === key)) return false;
  if (patch && patch.users) $users.set({ ...$users.get(), ...patch.users });
  if (patch && patch.rdpView) $rdpView.set(patch.rdpView);
  if (key !== 'users') $drawer.set(null);
  $tab.set(key);
  return true;
}

function openPage(key, patch) {
  if (!goTab(key, patch)) goTab('overview');
  host.navigate(ROUTE);
}

// ============================================================================
// §6 UI PRIMITIVES
// ============================================================================
function Badge({ tone, title, children }) {
  return jsx('span', { className: `hs-badge${tone ? ` ${tone}` : ''}`, title, children });
}

function TierTag({ tier }) {
  return jsx('span', { className: `hs-tier hs-tier-${tier}`, children: tier === 'P' ? 'PROTECTED' : tier });
}

function Dot({ tone }) {
  return jsx(StatusDot, { tone: tone || 'muted' });
}

function Callout({ tone, icon, children }) {
  return jsxs('div', {
    className: `hs-callout ${tone || 'accent'}`,
    children: [icon ? jsx('span', { children: icon }) : null, jsx('div', { children })],
  });
}

function ErrorBox({ error }) {
  const e = error || {};
  return jsx(Callout, {
    tone: 'red',
    icon: '⚠',
    children: jsxs('div', {
      children: [
        jsxs('div', { children: [jsx('b', { children: e.type || 'Error' }), `: ${e.message || 'Something went wrong.'}`] }),
        e.hint ? jsx('div', { className: 'hs-muted hs-small', children: e.hint }) : null,
      ],
    }),
  });
}

function Spinner({ label }) {
  return jsxs('div', { className: 'hs-loading', children: [jsx(GlyphSpinner, {}), jsx('span', { children: label || 'Loading…' })] });
}

// Renders children(data) once the query envelope is ok; spinner or error otherwise.
function Pending({ q, label, children }) {
  if (!q.res) return jsx(Spinner, { label });
  if (!q.res.ok) return jsx(ErrorBox, { error: q.res.error });
  return children(q.res.data || {});
}

function Btn({ kind, small, className, ...rest }) {
  const variant = kind === 'primary' ? 'default' : kind === 'solid-danger' ? 'destructive' : kind === 'ghost' ? 'ghost' : 'outline';
  const cls = [kind === 'danger' ? 'hs-danger' : '', className || ''].filter(Boolean).join(' ');
  return jsx(Button, { type: 'button', variant, size: small ? 'xs' : 'sm', className: cls || undefined, ...rest });
}

function Chip({ on, onClick, children }) {
  return jsx('button', { type: 'button', className: `hs-chip${on ? ' on' : ''}`, onClick, children });
}

function Seg({ value, options, onChange }) {
  return jsx('div', {
    className: 'hs-seg',
    children: options.map(([v, label]) =>
      jsx('button', { type: 'button', className: v === value ? 'on' : '', onClick: () => onChange(v), children: label }, v),
    ),
  });
}

function Field({ label, children }) {
  return jsxs('label', { className: 'hs-field', children: [jsx('span', { children: label }), children] });
}

function TextInput({ value, onChange, placeholder, mono, type, autoFocus, onEnter, list: listId }) {
  return jsx('input', {
    className: `hs-input${mono ? ' hs-mono' : ''}`,
    type: type || 'text',
    value: value === null || value === undefined ? '' : value,
    placeholder,
    autoFocus,
    list: listId,
    spellCheck: false,
    autoComplete: 'off',
    onChange: (e) => onChange(e.target.value),
    onKeyDown: onEnter ? (e) => { if (e.key === 'Enter') onEnter(); } : undefined,
  });
}

function TextArea({ value, onChange, placeholder, mono }) {
  return jsx('textarea', {
    className: `hs-input${mono ? ' hs-mono' : ''}`,
    value: value || '',
    placeholder,
    spellCheck: false,
    onChange: (e) => onChange(e.target.value),
  });
}

function CheckRow({ checked, onChange, label }) {
  return jsxs('label', {
    className: 'hs-check',
    children: [jsx('input', { type: 'checkbox', checked: !!checked, onChange: (e) => onChange(e.target.checked) }), jsx('span', { children: label })],
  });
}

function Toggle({ on, onChange, disabled, title }) {
  return jsx(Switch, { size: 'xs', checked: !!on, disabled, title, onCheckedChange: onChange });
}

function KV({ rows, keyWidth }) {
  return jsx('div', {
    className: 'hs-kv',
    style: keyWidth ? { gridTemplateColumns: `${keyWidth}px 1fr` } : undefined,
    children: rows.filter(Boolean).map(([k, v]) =>
      jsxs('div', { className: 'hs-kv-row', children: [jsx('span', { className: 'hs-k', children: k }), jsx('span', { children: v })] }, k),
    ),
  });
}

function Card({ title, sub, right, className, children }) {
  return jsxs('div', {
    className: `hs-card${className ? ` ${className}` : ''}`,
    children: [
      title
        ? jsxs('h3', { children: [title, sub ? jsx('span', { className: 'hs-sub', children: sub }) : null, jsx('span', { className: 'hs-grow' }), right || null] })
        : null,
      children,
    ],
  });
}

function Kpi({ value, label, sub, tone, onClick }) {
  return jsxs('button', {
    type: 'button',
    className: 'hs-kpi',
    onClick,
    children: [
      jsx('div', { className: 'hs-v', children: value }),
      jsx('div', { className: 'hs-l', children: label }),
      jsx('div', { className: `hs-s ${tone ? `hs-text-${tone}` : 'hs-muted'}`, children: sub || ' ' }),
    ],
  });
}

function Table({ head, children }) {
  return jsxs('table', {
    className: 'hs-table',
    children: [
      head ? jsx('thead', { children: jsx('tr', { children: head.map((h, i) => jsx('th', { children: h }, i)) }) }) : null,
      jsx('tbody', { children }),
    ],
  });
}

function EmptyRow({ cols, text }) {
  return jsx('tr', { children: jsx('td', { colSpan: cols, className: 'hs-empty-row', children: text }) });
}

function AuditDecision({ row }) {
  const failed = String(row.result || '').startsWith('failed');
  return jsx(Badge, { tone: decisionTone(row), title: row.result, children: `${row.decision}${failed ? ` · ${row.result}` : ''}` });
}

function SearchBox({ value, onChange, placeholder, focusSignal }) {
  const ref = useRef(null);
  useEffect(() => {
    if (focusSignal && ref.current) ref.current.focus();
  }, [focusSignal]);
  return jsx('input', {
    ref,
    className: 'hs-search',
    value,
    placeholder,
    spellCheck: false,
    onChange: (e) => onChange(e.target.value),
  });
}

// ============================================================================
// §7 DIALOGS AND THE CONFIRM FLOW
// ============================================================================
// One dialog at a time, held in $dialog. Every write goes through runWrite():
//   decision → allow: run · block: show the reason, no run button ·
//   approve W: confirm dialog (or the form that collected the args) → run with confirm:true ·
//   approve H: server preview + type-to-confirm → run with confirm:true + confirm_name.
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

function ConfirmWriteDialog({ seq, o, dec, opts }) {
  const s = useSubmit(seq, o, { confirm: true }, opts);
  return jsx(Modal, {
    seq,
    title: opts.title || 'Confirm change',
    tier: 'W',
    opName: o.name,
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
  const expected = String(dec.confirm_name || '');
  const match = expected !== '' && typed.trim().toLowerCase() === expected.trim().toLowerCase();
  const s = useSubmit(seq, o, { confirm: true, confirm_name: typed.trim() }, opts);
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
        jsxs('label', {
          className: 'hs-field',
          children: [
            jsxs('span', { children: ['Type ', jsx('b', { className: 'hs-mono', style: { color: 'var(--ui-text-primary)' }, children: expected }), ' to confirm'] }),
            jsx(TextInput, { value: typed, onChange: setTyped, mono: true, autoFocus: true, onEnter: () => { if (match && !s.busy) s.submit(); } }),
          ],
        }),
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
          icon: '🛡',
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
        icon: '✓',
        children: jsxs('div', {
          children: [
            jsxs('div', { children: ['Connected to ', jsx('b', { children: d.hostname || '—' }), ` · ${d.os || 'Windows'} · domain ${d.domain || '—'}`] }),
            jsx('div', { children: [mark('ActiveDirectory'), mark('GroupPolicy'), mark('WindowsServerBackup')].join(' · ') }),
            jsx('div', {
              className: 'hs-muted',
              children: `Identity ${d.identity || '—'} · ${d.is_domain_controller ? 'domain controller' : 'not a domain controller'} · PowerShell ${d.ps_version || '—'}`,
            }),
            list(d.privileged_memberships).length
              ? jsx('div', { className: 'hs-muted', children: `Privileged memberships: ${list(d.privileged_memberships).join(', ')}` })
              : null,
          ],
        }),
      }),
      ...list(d.warnings).map((w, i) => jsx(Callout, { tone: 'yellow', icon: '⚠', children: w }, `w${i}`)),
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
      jsx('div', { className: 'hs-big', children: '🏢' }),
      jsx('h2', { children: 'Connect to Active Directory' }),
      jsx('p', {
        className: 'hs-muted',
        children: 'Hermes reaches your domain through one WinRM jump host, which must be a domain controller. Credentials are stored in Hermes secrets.',
      }),
      jsxs('div', {
        className: 'hs-form',
        children: [
          jsx('div', { className: 'hs-label', children: 'Set these in the plugin settings' }),
          jsxs('ul', {
            className: 'hs-checklist',
            children: [
              jsx('li', { children: 'Jump host: the domain controller FQDN, e.g. dc01.corp.example.local' }),
              jsx('li', { children: 'WinRM port and HTTPS: 5986 with HTTPS, or 5985 (NTLM/Kerberos still encrypts)' }),
              jsx('li', { children: 'Authentication: NTLM or Kerberos' }),
              jsx('li', { children: 'Username, e.g. CORP\\svc-hermes, and its password (kept in Hermes secrets)' }),
            ],
          }),
          health && health.host ? jsx('div', { className: 'hs-muted hs-small', children: `Configured jump host: ${health.host}` }) : null,
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

function UpdatedAgo({ at }) {
  useTick(10000);
  return jsx('span', { className: 'hs-muted hs-small', children: at ? `updated ${ago(at)}` : 'loading…' });
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
      jsx('span', { className: 'hs-domain', children: `${domain || 'domain'} · via ${health.host || 'jump host'} (WinRM)` }),
      jsx('span', { className: 'hs-grow' }),
      jsx(Badge, { tone: 'accent', children: `mode: ${health.mode}` }),
      health.escape_enabled ? jsx(Badge, { tone: 'red', children: 'PowerShell escape hatch on' }) : null,
      jsx(UpdatedAgo, { at: overview.updatedAt }),
      jsx(Btn, { small: true, onClick: refresh, disabled: busy, children: busy ? 'Refreshing…' : '↻ Refresh' }),
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
          jsx(Btn, { onClick: () => openDialog(RecycleBinDialog, {}), children: '🗑 Recycle Bin' }),
          jsx(Btn, { kind: 'primary', onClick: () => openDialog(NewUserDialog, {}), children: '+ New user' }),
        ],
      }),
      jsx(Pending, {
        q,
        label: 'Loading users…',
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
    icon: '🔒',
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
          jsx('button', { type: 'button', className: 'hs-ghost', title: 'Close', onClick: () => $drawer.set(null), children: '✕' }),
        ],
      }),
      !u
        ? jsx('div', { className: 'hs-sec', children: jsx(Pending, { q, label: 'Loading user…', children: () => null }) })
        : jsxs('div', {
            children: [
              isProtected
                ? jsx('div', {
                    className: 'hs-sec',
                    children: jsx(Callout, {
                      tone: 'red',
                      icon: '🛡',
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
                                    children: '✕',
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
              jsx('span', { className: 'hs-muted hs-small', children: `${num(sum.sessions)} sessions · ${num(sum.active)} active · ${num(sum.disconnected)} disconnected · ${num(sum.reachable)}/${num(sum.hosts)} servers reachable` }),
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
                        jsx('td', { className: 'hs-muted', children: s.idle || '—' }),
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
              jsx(Btn, { small: true, kind: 'ghost', onClick: () => api.refresh().then(() => invalidateAll()), children: '↻ Recheck' }),
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

// ============================================================================
// §15 TAB REGISTRY
// ============================================================================
// badge(kpis) feeds the red count on the tab; overlay() renders above the page (the drawer).
const TABS = [
  { key: 'overview', label: 'Overview', badge: () => 0, render: () => jsx(OverviewTab, {}) },
  { key: 'users', label: 'Users', badge: (k) => k.users_locked, render: () => jsx(UsersTab, {}), overlay: () => jsx(UserDrawerHost, {}) },
  { key: 'gpo', label: 'Group Policy', badge: (k) => k.gpos_needing_attention, render: () => jsx(GpoTab, {}) },
  { key: 'rdp', label: 'Remote Access', badge: () => 0, render: () => jsx(RdpTab, {}) },
  { key: 'backups', label: 'Backups', badge: (k) => k.backups_bad, render: () => jsx(BackupsTab, {}) },
  { key: 'audit', label: 'Audit', badge: () => 0, render: () => jsx(AuditTab, {}) },
  // more tabs: later tasks insert their entries above this line
];

// ============================================================================
// §16 REGISTRATION
// ============================================================================
function focusUserSearch() {
  $focusSearch.set($focusSearch.get() + 1);
}

const PALETTE = [
  { id: 'overview', label: 'AD: Overview', keywords: ['active directory', 'domain', 'dc', 'health'], run: () => openPage('overview') },
  { id: 'find-user', label: 'AD: Find user…', keywords: ['active directory', 'user', 'search'], run: () => { openPage('users'); focusUserSearch(); } },
  { id: 'unlock-user', label: 'AD: Unlock user…', keywords: ['active directory', 'locked', 'lockout'], run: () => { openPage('users', { users: { status: 'locked', query: '' } }); focusUserSearch(); } },
  { id: 'sessions', label: 'AD: Sessions', keywords: ['rdp', 'remote desktop', 'logoff'], run: () => openPage('rdp', { rdpView: 'sessions' }) },
  // more palette entries: later tasks insert their entries above this line
];

export default {
  id: PLUGIN_ID,
  name: 'Active Directory',
  description: 'Hermes Sysadmin: users, Group Policy, Remote Desktop and backups for an Active Directory domain.',
  defaultEnabled: false,
  register(ctx) {
    CTX = ctx;
    ctx.registerMany([
      { id: 'page', area: ROUTES_AREA, data: { path: ROUTE }, render: () => jsx(Page, {}) },
      { id: 'nav', area: SIDEBAR_NAV_AREA, data: { path: ROUTE, label: 'Active Directory', codicon: 'organization' } },
      { id: 'status', area: STATUSBAR_AREAS.right, order: 140, render: () => jsx(StatusBarItem, {}) },
      ...PALETTE.map((p) => ({
        id: `palette-${p.id}`,
        area: PALETTE_AREA,
        data: { id: `hermes-sysadmin.${p.id}`, label: p.label, keywords: p.keywords, run: p.run },
      })),
    ]);
    // Live updates: every write (agent or dashboard) emits plugin.hermes-sysadmin.changed.
    // Polling in §5 (refetchInterval) covers missed events and changes made outside Hermes.
    ctx.onEvent(CHANGED_EVENT, () => { Promise.resolve().then(() => api.refresh()).catch(() => {}).then(() => invalidateAll()); });
    ctx.onDispose(() => {
      $dialog.set(null);
      $drawer.set(null);
    });
  },
};
