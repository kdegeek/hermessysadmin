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
  { id: 'fleet', label: 'AD: Fleet', keywords: ['computers', 'devices', 'inventory', 'workstations'], run: () => openPage('fleet') },
  { id: 'find-computer', label: 'AD: Find computer…', keywords: ['computer', 'device', 'search', 'fleet'], run: () => { openPage('fleet', { fleet: { filter: 'all', os: '', query: '' } }); focusUserSearch(); } },
  // more palette entries: later tasks insert their entries above this line
];

export default {
  id: PLUGIN_ID,
  name: 'Active Directory',
  description: 'Hermes Sysadmin: users, Group Policy, Remote Desktop and backups for an Active Directory domain.',
  defaultEnabled: true,
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
      $device.set(null);
    });
  },
};
