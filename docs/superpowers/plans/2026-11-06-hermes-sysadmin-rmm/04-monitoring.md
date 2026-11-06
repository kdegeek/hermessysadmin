# Phase 4: Monitoring

### Task 11: Monitor rules, alert state, watch script, cron setup

**Files:**
- Create: `sysadmin/monitor.py` (pure rule evaluation, plus the alert-state store)
- Create: `scripts/watch.py` (the cron entry point; prints new and resolved findings)
- Create: `sysadmin/ops/monitoring.py` (`monitoring_enable`, `monitoring_disable` and `monitoring_status` local ops)
- Modify: `sysadmin/config.py` and `plugin.yaml` `config_schema` (new settings)
- Modify: `sysadmin/ops/__init__.py`, `plugin.yaml` `provides_tools`, `sysadmin/api.py` + `dashboard/plugin_api.py` (`GET /monitoring`, `POST /monitoring/enable`, `POST /monitoring/disable`; the POSTs go through the same confirm contract as other W ops via the existing `run_op` path. Reuse `run_op`, don't add a parallel path)
- Test: `tests/test_monitor.py`

**Interfaces:**
- Consumes:
  - `fleet.get_store()`, `FleetStore.latest()`/`previous()` and `fleet.summarize` (Task 5).
  - `Service.call` with the existing ops `fleet_inventory` (`refresh: true`), `ad_user_list` (`status: locked`), `ad_group_get` (each privileged group: `Domain Admins`, `Enterprise Admins`, `Schema Admins`, `Administrators` + `settings.privileged_groups`), `gpo_health`, `backup_status` and `ad_dc_health`.
  - Check each op's actual result shape in the tests or fixtures (`tests/test_ops_*.py`), or by running the op once read-only in Task 16. Code defensively: a missing key means no finding, never a crash.
- Produces:
  - Settings fields (and `config_schema` entries with labels and descriptions):
    - `monitor_interval: str = "30m"`, which must match `^\d+[mh]$` (otherwise the default)
    - `alert_disk_free_pct: int = 10` (1–90)
    - `alert_offline_days: int = 7` (1–365)
    - `alert_patch_age_days: int = 45` (1–365)
    - `alert_privileged_changes: bool = True`
    - `alert_lockouts: bool = True`
  - `monitor.Finding = dataclass(rule: str, host: str, message: str, bucket: str = "")`, with `fingerprint` property `f"{rule}:{host.lower()}:{bucket}"`.
  - `monitor.evaluate(inputs: dict, settings, *, now) -> list[Finding]`. It is pure. `inputs` keys (each optional): `fleet` (inventory data), `previous_fleet` (prior snapshot items), `locked` (list of users), `privileged` (`{group: [member names]}`), `previous_privileged` (same), `gpo_health`, `backups`, `dc_health`. Rules, in order:

    | rule | finding when | host | bucket | message |
    |---|---|---|---|---|
    | `disk_low` | online and `c_free_pct < alert_disk_free_pct` | name | `str(c_free_pct // 5 * 5)` | `C: {pct}% free ({gb} GB)` |
    | `offline` | `online` is False, the host was online in `previous_fleet`, and `last_logon` is older than `alert_offline_days` | name | `""` | `offline; last seen {date}` |
    | `patch_age` | `patch_age_days > alert_patch_age_days` | name | `str(days // 30)` | `no update in {d} days` |
    | `reboot_pending` | `pending_reboot` and `uptime_days > 7` | name | `""` | `reboot pending, up {d} days` |
    | `defender_off` | `defender_rt is False` | name | `""` | `Defender real-time protection is off` |
    | `privileged_added` | the member is in `privileged[g]` and not in `previous_privileged[g]`, and `previous_privileged` is not None (first run sets the baseline) and `alert_privileged_changes` | group | member | `{member} added to {group}` |
    | `locked_out` | a user is in `locked` and `alert_lockouts` | sam | `""` | `account locked out` |
    | `gpo_problem` | each `gpo_health` item whose status is not OK (check the field name) | gpo name | status | `GPO {name}: {status}` |
    | `backup_stale` | each backup host whose `stale` is true or whose last result failed (check the field names) | host | `""` | `backup stale/failed: {detail}` |
    | `dc_health` | each DC check with status error/failed | dc | check name | `{check}: {detail}` |

  - `monitor.AlertState(conn)`. Tables: `alerts(fingerprint PRIMARY KEY, rule, host, message, first_seen, last_seen, active INTEGER)` and `kv(key PRIMARY KEY, value TEXT)`.
    - `diff(findings, *, now) -> (new: list[Finding], resolved: list[dict])`: it upserts the active ones and marks the missing active ones as resolved (`active=0`).
    - `open() -> list[dict]`
    - `get(key)` / `put(key, value)` for the privileged baseline and `last_run`
  - `monitor.get_state()` uses `plugin_db("hermes-sysadmin", "monitor.db")` with an in-memory fallback; `set_state` is for tests.
  - `monitor.render(new, resolved) -> str`. It returns `""` when both are empty. Otherwise it returns:

    ```
    **hermes-sysadmin**: N new, M resolved
    - 🔴 <host>: <message>    (one per new, max 25, then "- … and K more")
    - ✅ resolved: <host>: <message>
    ```

  - `monitor.run_once(service, settings, *, now=None) -> str`:
    1. Gather the inputs through `service.call(..., actor="monitor")`. Each call is wrapped; a failed call adds nothing, and `fleet_inventory` failure means the fleet rules are skipped.
    2. Load `previous_fleet` from `fleet.get_store().previous()` items.
    3. Load `previous_privileged` from state kv `privileged`, then store the current membership.
    4. Run `evaluate` and `diff`, put `last_run`, and return `render`.

    It never raises. On an unexpected error it returns `""` and logs; an exception in cron would spam.
  - `scripts/watch.py` puts the plugin root on `sys.path`, calls `load_hermes_dotenv()` (as `verify_live.py` does), then `load_settings()`. If the plugin is not configured it prints nothing and exits 0. It builds a Service (`runtime.build_service(settings)`), prints `run_once(...)` only when it is non-empty, and exits 0.
  - Local W op `monitoring_enable`. Params: `deliver` (string, required, the Hermes delivery target, e.g. `origin`, or a platform target as `hermes cron create --help` lists them), `mode` (enum `watchdog|agent`, default `watchdog`). Steps:
    1. Resolve `hermes_home` via `from hermes_constants import get_hermes_home`, or `hermes_cli.config.get_hermes_home`. Check which one exists in the installed Hermes (`grep -rn "def get_hermes_home" <hermes-agent>`).
    2. Write `<hermes_home>/scripts/hermes_sysadmin_watch.py` with the content `import runpy, sys; sys.argv=[r"<plugin_root>/scripts/watch.py"]; runpy.run_path(r"<plugin_root>/scripts/watch.py", run_name="__main__")`.
    3. If a job named `hermes-sysadmin-watch` exists, remove it first.
    4. Run `subprocess.run([sys.executable, "-m", "hermes_cli.main", "cron", "create", f"every {interval}" or the schedule syntax the CLI accepts, "--name", "hermes-sysadmin-watch", "--script", "hermes_sysadmin_watch.py", "--no-agent", "--deliver", deliver], capture_output=True, text=True, timeout=60)`. In `agent` mode use `--monitor-script` in place of `--script` + `--no-agent`, with the prompt `"hermes-sysadmin monitoring found changes. Use the fleet-health-check skill to triage them and summarize what needs attention."`.

    Before writing this, **read `hermes cron create --help` and the cron CLI source** in the local Hermes checkout (`/Users/kdegeek/.hermes/hermes-agent` or `find / -path '*hermes_cli/cron*' 2>/dev/null | head`) and match the exact argument names and schedule syntax. If the CLI cannot be found locally, report NEEDS_CONTEXT.

    It returns `{"enabled": True, "job": "hermes-sysadmin-watch", "interval", "deliver", "mode", "stdout": <trimmed>}`. A non-zero exit raises `SysadminError` with stderr.

    Preview (it is W, so `preview=True`) returns `{"summary": "Create Hermes cron job hermes-sysadmin-watch every <interval> delivering to <deliver>", "changes": [<launcher path write>, <cron command line>], "current": <status>}`. Local ops with preview: check how `Service.preview` handles `op.local`. If it doesn't support local previews, add `local_preview: Callable | None` to `Op` and use it in `Service.preview`, with a test.
  - Local W op `monitoring_disable` (preview lists the job to remove). It runs `cron remove hermes-sysadmin-watch` (match the CLI's real subcommand).
  - Local R op `monitoring_status` returns `{"enabled": bool, "job": {...}|None, "interval", "deliver", "last_run", "open_alerts": [...]}`. `job` comes from `cron list --json` if the CLI has JSON output; otherwise parse the text. `open_alerts` comes from `get_state().open()`.

- [ ] **Step 1: Write the failing tests** (`tests/test_monitor.py`):

```python
import sqlite3
from datetime import datetime, timedelta, timezone

from sysadmin import monitor
from sysadmin.config import Settings

NOW = datetime(2026, 11, 6, 12, tzinfo=timezone.utc)
S = Settings(host="dc", username="u", password="p")


def host(name, **kw):
    base = {"name": name, "online": True, "c_free_pct": 50, "c_free_gb": 100, "patch_age_days": 5,
            "pending_reboot": False, "uptime_days": 1, "defender_rt": True,
            "last_logon": (NOW - timedelta(days=1)).isoformat()}
    base.update(kw)
    return base


def rules(findings):
    return sorted((f.rule, f.host) for f in findings)


def test_fleet_rules():
    fl = {"items": [host("A", c_free_pct=4, c_free_gb=3), host("B", patch_age_days=60),
                    host("C", pending_reboot=True, uptime_days=9), host("D", defender_rt=False),
                    host("E", online=False, last_logon=(NOW - timedelta(days=10)).isoformat())]}
    prev = [host("E")]
    got = monitor.evaluate({"fleet": fl, "previous_fleet": prev}, S, now=NOW)
    assert rules(got) == [("defender_off", "D"), ("disk_low", "A"), ("offline", "E"), ("patch_age", "B"),
                          ("reboot_pending", "C")]


def test_privileged_baseline_then_change():
    assert monitor.evaluate({"privileged": {"Domain Admins": ["a"]}, "previous_privileged": None}, S, now=NOW) == []
    got = monitor.evaluate({"privileged": {"Domain Admins": ["a", "eve"]},
                            "previous_privileged": {"Domain Admins": ["a"]}}, S, now=NOW)
    assert [(f.rule, f.host, f.bucket) for f in got] == [("privileged_added", "Domain Admins", "eve")]


def test_state_diff_new_then_silent_then_resolved():
    st = monitor.AlertState(sqlite3.connect(":memory:"))
    f = monitor.Finding("disk_low", "A", "C: 4% free", "0")
    new, res = st.diff([f], now=NOW)
    assert len(new) == 1 and res == []
    assert st.diff([f], now=NOW) == ([], [])
    new, res = st.diff([], now=NOW)
    assert new == [] and res[0]["host"] == "A"


def test_render_empty_is_silent():
    assert monitor.render([], []) == ""
    out = monitor.render([monitor.Finding("disk_low", "A", "C: 4% free")], [])
    assert out.startswith("**hermes-sysadmin**: 1 new, 0 resolved") and "A: C: 4% free" in out


def test_run_once_never_raises():
    class Boom:
        def call(self, *a, **k):
            raise RuntimeError("x")
    monitor.set_state(monitor.AlertState(sqlite3.connect(":memory:")))
    assert monitor.run_once(Boom(), S, now=NOW) == ""


def test_settings_defaults():
    from sysadmin.config import settings_from
    s = settings_from({"monitor_interval": "bad"}, "")
    assert (s.monitor_interval, s.alert_disk_free_pct, s.alert_offline_days, s.alert_patch_age_days) == ("30m", 10, 7, 45)
```

  Plus a test that `monitoring_enable` builds the right command. Monkeypatch `subprocess.run` in `sysadmin.ops.monitoring` and the hermes-home resolver to `tmp_path`, then assert:
  - the argv contains `"cron"`, `"create"`, `"--name"`, `"hermes-sysadmin-watch"`, `"--script"`, `"hermes_sysadmin_watch.py"`, `"--no-agent"`, `"--deliver"` and the target;
  - the launcher file exists under `tmp_path/"scripts"`;
  - the op's tier is W.

- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement** the settings, `monitor.py`, `scripts/watch.py`, the ops and the routes.
- [ ] **Step 4: Run** the full suite. Expected: pass.
- [ ] **Step 5: Commit.** `git commit -m "feat: scheduled monitoring: alert rules with fingerprint dedupe, silent-when-clean watch script, cron enable/disable/status"` (add files first)
