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

