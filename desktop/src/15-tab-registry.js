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

