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

