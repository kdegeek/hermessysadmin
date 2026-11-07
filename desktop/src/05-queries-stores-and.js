// ============================================================================
// §5 QUERIES, STORES AND HOOKS
// ============================================================================
// React Query (the app's shared QueryClient) caches, dedupes and polls; the backend's
// change event invalidates everything under KEY.all (see §16).
const KEY = {
  all: [PLUGIN_ID],
  health: [PLUGIN_ID, 'health'],
  overview: [PLUGIN_ID, 'overview'],
  fleet: [PLUGIN_ID, 'fleet'],
  fleetHistory: (days) => [PLUGIN_ID, 'fleet-history', days],
  fleetDevice: (n) => [PLUGIN_ID, 'fleet-device', n],
  remoteSessions: (n) => [PLUGIN_ID, 'remote-sessions', n],
  remoteCheck: (n) => [PLUGIN_ID, 'remote-check', n],
  monitoring: [PLUGIN_ID, 'monitoring'],
  catalog: [PLUGIN_ID, 'catalog'],
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

// Inventory can take up to a minute on a cold cache, so nothing waits on it.
function useFleet(enabled) {
  return useApi(KEY.fleet, () => api.fleet(false), { refetchInterval: POLL.fleet, staleTime: POLL.fleet, enabled });
}

function useFleetHistory(days, enabled) {
  return useApi(KEY.fleetHistory(days), () => api.fleetHistory(days), { refetchInterval: POLL.fleet, staleTime: POLL.fleet, enabled });
}

function useMonitoring(enabled) {
  return useApi(KEY.monitoring, api.monitoring, { refetchInterval: POLL.overview, enabled });
}

function useCatalog(enabled) {
  return useApi(KEY.catalog, api.catalog, { staleTime: 300000, enabled });
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
// Fleet tab filter, set by Overview drill-downs: filter in all|online|offline|low_disk|reboot|patch_old|defender_off|bitlocker_off|rdp_no_nla.
const $fleet = atom({ filter: 'all', os: '', query: '' });
// Computer shown in the Fleet device drawer, and the host names ticked in the Fleet table.
const $device = atom(null);
const $fleetSelection = atom([]);
// Computers handed to the Catalog tab by openCatalogRun (shown there as the selected-devices target).
const $catalogComputers = atom([]);
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
  if (patch && patch.fleet) $fleet.set({ filter: 'all', os: '', query: '', ...patch.fleet });
  if (patch && patch.catalog) $catalogComputers.set(list(patch.catalog.computers));
  if (patch && patch.rdpView) $rdpView.set(patch.rdpView);
  if (key !== 'users') $drawer.set(null);
  if (key !== 'fleet') $device.set(null);
  $tab.set(key);
  return true;
}

function openPage(key, patch) {
  if (!goTab(key, patch)) goTab('overview');
  host.navigate(ROUTE);
}

