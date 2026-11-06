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
        jsx('div', { className: 'hs-muted hs-small', children: `${dec.reason} Preview from the server (-WhatIf). Nothing has changed yet.` }),
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
// §15 TAB REGISTRY
// ============================================================================
// badge(kpis) feeds the red count on the tab; overlay() renders above the page (the drawer).
const TABS = [
  { key: 'overview', label: 'Overview', badge: () => 0, render: () => jsx(OverviewTab, {}) },
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
    ctx.onEvent(CHANGED_EVENT, () => invalidateAll());
    ctx.onDispose(() => {
      $dialog.set(null);
      $drawer.set(null);
    });
  },
};
