import sqlite3
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace

import pytest

from sysadmin import fleet, monitor
from sysadmin.config import Settings
from sysadmin.ops import monitoring
from sysadmin.registry import OPS

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


def test_fleet_rule_details_and_edges():
    got = monitor.evaluate({"fleet": {"items": [host("A", c_free_pct=7, c_free_gb=12, patch_age_days=95)]},
                            "previous_fleet": []}, S, now=NOW)
    by = {f.rule: f for f in got}
    assert (by["disk_low"].bucket, by["disk_low"].message) == ("5", "C: 7% free (12 GB)")
    assert (by["patch_age"].bucket, by["patch_age"].message) == ("3", "no update in 95 days")
    # offline needs a prior online sighting; an offline host that was already offline stays quiet
    off = host("E", online=False, last_logon=(NOW - timedelta(days=10)).isoformat())
    assert monitor.evaluate({"fleet": {"items": [off]}, "previous_fleet": [dict(off)]}, S, now=NOW) == []
    # offline hosts are not disk alerts; missing keys never crash
    assert monitor.evaluate({"fleet": {"items": [host("F", online=False, c_free_pct=1), {"name": "G"}, {}]}}, S, now=NOW) == []


def test_privileged_baseline_then_change():
    assert monitor.evaluate({"privileged": {"Domain Admins": ["a"]}, "previous_privileged": None}, S, now=NOW) == []
    got = monitor.evaluate({"privileged": {"Domain Admins": ["a", "eve"]},
                            "previous_privileged": {"Domain Admins": ["a"]}}, S, now=NOW)
    assert [(f.rule, f.host, f.bucket) for f in got] == [("privileged_added", "Domain Admins", "eve")]
    off = Settings(alert_privileged_changes=False)
    assert monitor.evaluate({"privileged": {"Domain Admins": ["a", "eve"]},
                             "previous_privileged": {"Domain Admins": ["a"]}}, off, now=NOW) == []


def test_other_rules():
    inputs = {
        "locked": [{"sam": "bob"}],
        "gpo_health": {"items": [{"name": "Old GPO", "health": ["Unlinked"]}]},
        "backups": {"items": [{"host": "srv1", "state": "bad", "stale": True, "message": "3.0 days old"},
                              {"host": "srv2", "state": "ok", "stale": False}]},
        "dc_health": {"items": [{"name": "DC1", "status": "bad", "reachable": True,
                                 "services": {"NTDS": "Stopped", "Netlogon": "Running", "KDC": "Running"}},
                                {"name": "DC2", "status": "warn"}]},
    }
    got = monitor.evaluate(inputs, S, now=NOW)
    assert rules(got) == [("backup_stale", "srv1"), ("dc_health", "DC1"), ("gpo_problem", "Old GPO"), ("locked_out", "bob")]
    assert [f.message for f in got if f.rule == "dc_health"] == ["service NTDS: NTDS is Stopped"]
    assert monitor.evaluate({"locked": [{"sam": "bob"}]}, Settings(alert_lockouts=False), now=NOW) == []
    assert monitor.evaluate({"locked": "junk", "gpo_health": None, "backups": 3, "dc_health": [1]}, S, now=NOW) == []


def test_fingerprint():
    assert monitor.Finding("disk_low", "PC-A", "m", "5").fingerprint == "disk_low:pc-a:5"


def test_state_diff_new_then_silent_then_resolved():
    st = monitor.AlertState(sqlite3.connect(":memory:"))
    f = monitor.Finding("disk_low", "A", "C: 4% free", "0")
    new, res = st.diff([f], now=NOW)
    assert len(new) == 1 and res == []
    assert st.diff([f], now=NOW) == ([], [])
    assert [a["host"] for a in st.open()] == ["A"]
    new, res = st.diff([], now=NOW)
    assert new == [] and res[0]["host"] == "A" and st.open() == []
    new, _ = st.diff([f], now=NOW)  # recurs after resolving: new again
    assert len(new) == 1


def test_state_diff_scope_and_one_shot():
    st = monitor.AlertState(sqlite3.connect(":memory:"))
    disk = monitor.Finding("disk_low", "A", "m", "0")
    priv = monitor.Finding("privileged_added", "Domain Admins", "eve added to Domain Admins", "eve")
    st.diff([disk, priv], now=NOW)
    # a source that could not be read does not resolve its alerts
    assert st.diff([], now=NOW, scope={"locked_out"}) == ([], [])
    new, res = st.diff([], now=NOW, scope={"disk_low", "privileged_added"})
    assert [r["rule"] for r in res] == ["disk_low"]  # the one-shot privileged alert clears silently
    assert st.open() == []


def test_kv():
    st = monitor.AlertState(sqlite3.connect(":memory:"))
    assert st.get("k") is None
    st.put("k", "1")
    st.put("k", "2")
    assert st.get("k") == "2"


def test_render_empty_is_silent():
    assert monitor.render([], []) == ""
    out = monitor.render([monitor.Finding("disk_low", "A", "C: 4% free")], [])
    assert out.startswith("**hermes-sysadmin**: 1 new, 0 resolved") and "A: C: 4% free" in out


def test_render_caps_and_resolved():
    new = [monitor.Finding("disk_low", f"H{i}", "m") for i in range(30)]
    out = monitor.render(new, [{"host": "Z", "message": "gone"}])
    lines = out.splitlines()
    assert lines[0] == "**hermes-sysadmin**: 30 new, 1 resolved"
    assert lines.count("- … and 5 more") == 1 and sum(l.startswith("- 🔴") for l in lines) == 25
    assert lines[-1] == "- ✅ resolved: Z: gone"


def test_run_once_never_raises():
    class Boom:
        def call(self, *a, **k):
            raise RuntimeError("x")
    monitor.set_state(monitor.AlertState(sqlite3.connect(":memory:")))
    assert monitor.run_once(Boom(), S, now=NOW) == ""

    class BadState:
        def __getattr__(self, name):
            raise RuntimeError("db gone")
    monitor.set_state(BadState())
    assert monitor.run_once(Boom(), S, now=NOW) == ""
    monitor.set_state(None)


class FakeService:
    def __init__(self, responses):
        self.responses = responses
        self.calls = []

    def call(self, name, args=None, *, actor, **kw):
        self.calls.append((name, dict(args or {}), actor))
        r = self.responses.get(name)
        if callable(r):
            r = r(dict(args or {}))
        return r if r is not None else {"ok": False, "error": {"type": "X", "message": "no"}}


@pytest.fixture
def stores():
    st = monitor.AlertState(sqlite3.connect(":memory:", check_same_thread=False))
    monitor.set_state(st)
    fs = fleet.FleetStore(sqlite3.connect(":memory:", check_same_thread=False))
    fleet.set_store(fs)
    yield st, fs
    monitor.set_state(None)
    fleet.set_store(None)


def ok(data):
    return {"ok": True, "data": data}


def test_run_once_end_to_end_dedupes_and_resolves(stores):
    st, fs = stores
    fs.record({"taken_at": "2026-11-06T10:00:00+00:00", "items": [host("A")], "kind": "any"})
    state = {"free": 3, "da": ["admin"]}
    svc = FakeService({
        "fleet_inventory": lambda a: ok({"items": [host("A", c_free_pct=state["free"])]}),
        "ad_group_get": lambda a: ok({"members": [{"sam": m} for m in (state["da"] if a["identity"] == "Domain Admins" else ["x"])]}),
        "ad_user_list": ok({"items": []}),
    })
    first = monitor.run_once(svc, S, now=NOW)
    assert "1 new, 0 resolved" in first and "A: C: 3% free" in first  # privileged first run is a baseline only
    assert all(c[2] == "monitor" for c in svc.calls)
    assert st.get("last_run") == NOW.isoformat() and "Domain Admins" in st.get("privileged")
    assert monitor.run_once(svc, S, now=NOW) == ""  # nothing changed: silent
    state.update(free=60, da=["admin", "eve"])
    out = monitor.run_once(svc, S, now=NOW)
    assert "1 new, 1 resolved" in out and "eve added to Domain Admins" in out and "resolved: A" in out
    assert monitor.run_once(svc, S, now=NOW) == ""  # the privileged alert does not "resolve" next run


def test_failed_source_does_not_resolve_its_alerts(stores):
    st, _ = stores
    ok_svc = FakeService({"fleet_inventory": ok({"items": [host("A", c_free_pct=3)]})})
    assert "1 new" in monitor.run_once(ok_svc, S, now=NOW)
    assert monitor.run_once(FakeService({}), S, now=NOW) == ""  # inventory down: no fake "resolved"
    assert len(st.open()) == 1


def test_offline_alert_survives_next_snapshot(stores):
    st, fs = stores
    old = (NOW - timedelta(days=10)).isoformat()
    fs.record({"taken_at": "2026-11-06T10:00:00+00:00", "items": [host("E")], "kind": "any"})
    offline = ok({"items": [host("E", online=False, last_logon=old)]})
    svc = FakeService({"fleet_inventory": lambda a: (fs.record({"taken_at": svc_clock.pop(0), "items": [host("E", online=False, last_logon=old)], "kind": "any"}), offline)[1]})
    svc_clock = ["2026-11-06T11:00:00+00:00", "2026-11-06T11:30:00+00:00"]
    assert "E: offline" in monitor.run_once(svc, S, now=NOW)
    assert monitor.run_once(svc, S, now=NOW) == ""  # previous snapshot already offline, alert still open
    assert len(st.open()) == 1


def test_get_state_falls_back_to_memory():
    monitor.set_state(None)
    st = monitor.get_state()
    st.put("a", "b")
    assert monitor.get_state() is st
    monitor.set_state(None)


def test_settings_defaults():
    from sysadmin.config import settings_from
    s = settings_from({"monitor_interval": "bad"}, "")
    assert (s.monitor_interval, s.alert_disk_free_pct, s.alert_offline_days, s.alert_patch_age_days) == ("30m", 10, 7, 45)
    assert s.alert_privileged_changes is True and s.alert_lockouts is True


def test_settings_parse_and_bounds():
    from sysadmin.config import settings_from
    s = settings_from({"monitor_interval": "2h", "alert_disk_free_pct": "15", "alert_offline_days": 0,
                       "alert_patch_age_days": 400, "alert_lockouts": "false"}, "")
    assert (s.monitor_interval, s.alert_disk_free_pct, s.alert_offline_days, s.alert_patch_age_days) == ("2h", 15, 7, 45)
    assert s.alert_lockouts is False
    assert settings_from({"monitor_interval": "0m"}, "").monitor_interval == "30m"
    assert settings_from({"monitor_interval": "30 m"}, "").monitor_interval == "30m"


# ---- cron ops ---------------------------------------------------------------

LIST_OUT = """
┌───┐
  \x1b[33mabc123\x1b[0m [active]
    Name:      hermes-sysadmin-watch
    Schedule:  every 30m
    Repeat:    ∞
    Next run:  2026-11-06T12:30:00
    Deliver:   origin
    Script:    hermes_sysadmin_watch.py

  other99 [paused]
    Name:      something-else
"""


class CronFake:
    def __init__(self, list_out="No scheduled jobs.", fail=None):
        self.calls, self.list_out, self.fail = [], list_out, fail

    def __call__(self, argv, **kw):
        self.calls.append((argv, kw))
        sub = argv[argv.index("cron") + 1]
        if self.fail == sub:
            return subprocess.CompletedProcess(argv, 1, "Failed to create job: nope\n", "")
        return subprocess.CompletedProcess(argv, 0, self.list_out if sub == "list" else f"{sub} ok\n", "")


@pytest.fixture
def cron(monkeypatch, tmp_path):
    fake = CronFake()
    monkeypatch.setattr(monitoring.subprocess, "run", fake)
    monkeypatch.setattr(monitoring, "_hermes_home", lambda: tmp_path)
    monkeypatch.setattr(monitoring, "_hermes_root", lambda: "/hermes-agent")
    monitor.set_state(monitor.AlertState(sqlite3.connect(":memory:", check_same_thread=False)))
    yield fake
    monitor.set_state(None)


def svc(**kw):
    return SimpleNamespace(settings=Settings(host="dc", username="u", password="p", **kw))


def test_parse_jobs_strips_ansi():
    jobs = monitoring.parse_jobs(LIST_OUT)
    assert [j["name"] for j in jobs] == ["hermes-sysadmin-watch", "something-else"]
    assert jobs[0]["state"] == "active" and jobs[0]["schedule"] == "every 30m" and jobs[0]["next_run"].startswith("2026")
    assert monitoring.parse_jobs("  abc123 [active]\n    Name:      hermes-sysadmin-watch\n    Deliver:   origin\n")[0]["deliver"] == "origin"


def test_enable_builds_command(cron, tmp_path):
    op = OPS["monitoring_enable"]
    assert op.tier == "W" and op.preview and op.local_preview is not None
    out = op.local(svc(monitor_interval="15m"), {"deliver": "origin", "mode": "watchdog"})
    assert out["enabled"] is True and out["interval"] == "15m" and out["deliver"] == "origin"
    argv, kw = cron.calls[-1]
    assert argv[1:4] == ["-m", "hermes_cli.main", "cron"] and kw["cwd"] == "/hermes-agent"
    assert argv[argv.index("create") + 1] == "every 15m"
    for token in ("--name", "hermes-sysadmin-watch", "--script", "hermes_sysadmin_watch.py", "--no-agent", "--deliver", "origin"):
        assert token in argv
    launcher = tmp_path / "scripts" / "hermes_sysadmin_watch.py"
    text = launcher.read_text(encoding="utf-8")
    assert "runpy.run_path" in text and "watch.py" in text
    compile(text, "launcher", "exec")


def test_enable_agent_mode(cron, tmp_path):
    OPS["monitoring_enable"].local(svc(), {"deliver": "telegram", "mode": "agent"})
    argv = cron.calls[-1][0]
    assert "--monitor-script" in argv and "--no-agent" not in argv and "--script" not in argv
    assert argv[argv.index("create") + 2].startswith("hermes-sysadmin monitoring found changes")
    assert argv[argv.index("--monitor-script") + 1] == "hermes_sysadmin_watch_state.py"
    state_launcher = (tmp_path / "scripts" / "hermes_sysadmin_watch_state.py").read_text(encoding="utf-8")
    assert "'--state'" in state_launcher and "--state" not in (tmp_path / "scripts" / "hermes_sysadmin_watch.py").read_text(encoding="utf-8")


@pytest.mark.parametrize("mode", ["watchdog", "agent"])
def test_create_argv_parses_with_hermes_cli(mode):
    import sys
    root = "/Users/kdegeek/.hermes/hermes-agent"
    if root not in sys.path:
        sys.path.insert(0, root)
    try:
        import argparse
        from hermes_cli.subcommands.cron import build_cron_parser
    except Exception:
        argv = monitoring._create_args({"deliver": "origin", "mode": mode}, "30m")
        flags = [i for i, a in enumerate(argv) if a.startswith("--")]
        assert flags[0] >= 1 and all(not a.startswith("--") for a in argv[:flags[0]]) and argv[flags[0]:][0] == "--name"
        assert mode == "watchdog" or flags[0] == 2
        return
    parser = argparse.ArgumentParser()
    build_cron_parser(parser.add_subparsers(dest="cmd"), cmd_cron=lambda a: 0)
    ns = parser.parse_args(["cron", "create", *monitoring._create_args({"deliver": "origin", "mode": mode}, "30m")])
    assert ns.schedule == "every 30m" and ns.name == "hermes-sysadmin-watch" and ns.deliver == "origin"
    if mode == "agent":
        assert ns.prompt == monitoring.AGENT_PROMPT and ns.monitor_script == "hermes_sysadmin_watch_state.py" and not ns.no_agent
    else:
        assert ns.prompt is None and ns.script == "hermes_sysadmin_watch.py" and ns.no_agent


def test_enable_replaces_existing_job(cron):
    cron.list_out = LIST_OUT
    OPS["monitoring_enable"].local(svc(), {"deliver": "origin"})
    subs = [c[0][c[0].index("cron") + 1] for c in cron.calls]
    assert subs == ["list", "create", "remove"]  # create first; the old id is removed only after it succeeded
    assert cron.calls[2][0][-1] == "abc123"


def test_failed_create_leaves_old_job(cron):
    from sysadmin.errors import SysadminError
    cron.list_out = LIST_OUT
    cron.fail = "create"
    with pytest.raises(SysadminError, match="left untouched"):
        OPS["monitoring_enable"].local(svc(), {"deliver": "origin"})
    assert not any(c[0][c[0].index("cron") + 1] == "remove" for c in cron.calls)


def test_disable_removes_every_duplicate(cron):
    cron.list_out = LIST_OUT + "\n  dup777 [active]\n    Name:      hermes-sysadmin-watch\n"
    assert OPS["monitoring_disable"].local(svc(), {})["count"] == 2
    removed = [c[0][-1] for c in cron.calls if c[0][c[0].index("cron") + 1] == "remove"]
    assert removed == ["abc123", "dup777"]


def test_enable_failure_and_bad_target(cron):
    from sysadmin.errors import InvalidArguments, SysadminError
    cron.fail = "create"
    with pytest.raises(SysadminError, match="nope"):
        OPS["monitoring_enable"].local(svc(), {"deliver": "origin"})
    with pytest.raises(InvalidArguments):
        OPS["monitoring_enable"].local(svc(), {"deliver": "--paused"})


def test_enable_preview_via_service(cron, tmp_path):
    from conftest import FakeRunner
    from sysadmin.audit import AuditLog
    from sysadmin.service import Service
    s = Service(Settings(host="dc", username="u", password="p"), FakeRunner(), AuditLog(sqlite3.connect(":memory:", check_same_thread=False)))
    res = s.preview("monitoring_enable", {"deliver": "origin"})
    assert res["ok"] and res["data"]["summary"] == "Create Hermes cron job hermes-sysadmin-watch every 30m delivering to origin"
    changes = res["data"]["changes"]
    assert len(changes) == 3 and "current" in res["data"]
    assert changes[0].endswith("hermes_sysadmin_watch.py") and changes[1].endswith("hermes_sysadmin_watch_state.py")
    assert not (tmp_path / "scripts").exists()  # preview writes nothing
    assert all("create" not in c[0] for c in cron.calls)


def test_disable_and_status(cron):
    cron.list_out = LIST_OUT
    monitor.get_state().put("last_run", "t0")
    st = OPS["monitoring_status"].local(svc(), {})
    assert st["enabled"] is True and st["job"]["id"] == "abc123" and st["interval"] == "every 30m"
    assert st["deliver"] == "origin" and st["last_run"] == "t0" and st["open_alerts"] == []
    assert st["settings"]["alert_disk_free_pct"] == 10 and "alert_patch_age_days" in st["settings"]
    assert OPS["monitoring_disable"].local(svc(), {})["removed"] is True
    assert cron.calls[-1][0][-2:] == ["remove", "abc123"]
    cron.list_out = "No scheduled jobs"
    assert OPS["monitoring_status"].local(svc(), {})["enabled"] is False
    assert OPS["monitoring_disable"].local(svc(), {})["removed"] is False


def test_status_survives_cli_failure(cron):
    cron.fail = "list"
    st = OPS["monitoring_status"].local(svc(), {})
    assert st["enabled"] is False and "error" in st


def test_watch_script_is_silent(monkeypatch, capsys):
    import importlib.util
    from pathlib import Path
    spec = importlib.util.spec_from_file_location("watch_under_test", Path(__file__).resolve().parent.parent / "scripts" / "watch.py")
    watch = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(watch)
    from sysadmin import config, runtime
    monkeypatch.setattr(config, "load_settings", lambda: Settings())
    assert watch.main() == 0 and capsys.readouterr().out == ""
    configured = Settings(host="dc", username="u", password="p")
    monkeypatch.setattr(config, "load_settings", lambda: configured)
    closed = []
    monkeypatch.setattr(runtime, "build_service", lambda s: SimpleNamespace(runner=SimpleNamespace(close=lambda: closed.append(1))))
    monkeypatch.setattr(monitor, "run_once", lambda service, settings: "")
    assert watch.main() == 0 and capsys.readouterr().out == "" and closed
    monkeypatch.setattr(monitor, "run_once", lambda service, settings: "**hermes-sysadmin**: 1 new, 0 resolved")
    assert watch.main() == 0 and "1 new" in capsys.readouterr().out
    monkeypatch.setattr(runtime, "build_service", lambda s: 1 / 0)
    assert watch.main() == 0 and capsys.readouterr().out == ""


def test_monitoring_posts_use_the_confirm_contract(cron):
    from conftest import FakeRunner
    from sysadmin import api
    from sysadmin.audit import AuditLog
    from sysadmin.service import Service
    audit = AuditLog(sqlite3.connect(":memory:", check_same_thread=False))
    s = Service(Settings(host="dc", username="u", password="p"), FakeRunner(), audit)
    body = {"args": {"deliver": "origin"}}
    r = api.monitoring_enable(s, body)
    assert r["ok"] is False and r["error"]["type"] == "ApprovalRequired" and not any("create" in c[0] for c in cron.calls)
    r = api.monitoring_enable(s, {**body, "confirm": True})
    assert r["ok"] is True and r["data"]["enabled"] is True
    assert audit.query(limit=1)[0]["tool"] == "monitoring_enable"
    assert api.monitoring_disable(s, {"confirm": True})["ok"] is True
    assert api.monitoring(s)["data"]["enabled"] is False
    # read-only mode blocks the writes
    ro = Service(Settings(host="dc", username="u", password="p", mode="read-only"), FakeRunner(), audit)
    assert api.monitoring_enable(ro, {**body, "confirm": True})["error"]["type"] == "PolicyBlocked"


def test_privileged_baseline_written_only_after_diff(stores, monkeypatch):
    st, _ = stores
    state = {"da": ["admin"]}
    svc_ = FakeService({
        "fleet_inventory": ok({"items": []}),
        "ad_group_get": lambda a: ok({"members": [{"sam": m} for m in (state["da"] if a["identity"] == "Domain Admins" else [])]}),
    })
    monitor.run_once(svc_, S, now=NOW)  # baseline
    state["da"] = ["admin", "eve"]
    real = st.diff
    monkeypatch.setattr(st, "diff", lambda *a, **k: (_ for _ in ()).throw(RuntimeError("db locked")))
    assert monitor.run_once(svc_, S, now=NOW) == ""
    monkeypatch.setattr(st, "diff", real)
    assert "eve added to Domain Admins" in monitor.run_once(svc_, S, now=NOW)


def test_inventory_requests_every_computer_kind(stores):
    svc_ = FakeService({"fleet_inventory": ok({"items": []})})
    monitor.run_once(svc_, S, now=NOW)
    assert ("fleet_inventory", {"refresh": True, "kind": "any"}, "monitor") in svc_.calls


def test_dc_warn_only_alerts_on_replication_and_backup_errors():
    inputs = {
        "dc_health": {"items": [
            {"name": "DC1", "status": "warn", "reachable": True, "services": {"DNS": "Stopped"}, "replication": {"failures": 2}},
            {"name": "DC2", "status": "warn", "reachable": True, "time_skew_seconds": 90}]},
        "backups": {"items": [], "errors": [{"host": "srv9", "message": "timed out"}]},
    }
    got = monitor.evaluate(inputs, S, now=NOW)
    assert [(f.rule, f.host, f.bucket) for f in got] == [("backup_stale", "srv9", "unreachable"), ("dc_health", "DC1", "replication")]
    assert got[0].message == "unreachable: timed out"


def test_state_output_is_stable_across_runs(stores):
    st, _ = stores
    svc_ = FakeService({"fleet_inventory": lambda a: ok({"items": [host("B", c_free_pct=3, c_free_gb=n[0]), host("A", defender_rt=False)]})})
    n = [5]
    monitor.run_once(svc_, S, now=NOW)
    first = monitor.render_open(st.open())
    n[0] = 4  # free GB fluctuates, the alert set does not
    monitor.run_once(svc_, S, now=NOW + timedelta(minutes=30))
    assert monitor.render_open(st.open()) == first
    lines = first.splitlines()
    assert lines[0] == "**hermes-sysadmin**: 2 open alerts" and lines[1:] == sorted(lines[1:])
    assert monitor.render_open([]) == ""


def test_watch_state_flag(monkeypatch, capsys, stores):
    import importlib.util
    from pathlib import Path
    spec = importlib.util.spec_from_file_location("watch_state_under_test", Path(__file__).resolve().parent.parent / "scripts" / "watch.py")
    watch = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(watch)
    from sysadmin import config, runtime
    st, _ = stores
    st.diff([monitor.Finding("defender_off", "A", "Defender real-time protection is off")], now=NOW)
    configured = Settings(host="dc", username="u", password="p")
    monkeypatch.setattr(config, "load_settings", lambda: configured)
    monkeypatch.setattr(runtime, "build_service", lambda s: SimpleNamespace(runner=SimpleNamespace(close=lambda: None)))
    monkeypatch.setattr(monitor, "run_once", lambda service, settings: "delta text")
    assert watch.main(["--state"]) == 0
    out = capsys.readouterr().out
    assert "1 open alert" in out and "delta text" not in out
    assert watch.main([]) == 0 and capsys.readouterr().out.strip() == "delta text"


def test_monitor_previous_ignores_other_kinds(stores):
    _, fs = stores
    fs.record({"taken_at": "2026-11-06T10:00:00+00:00", "items": [host("ONLYWS")], "kind": "workstation"})
    inputs, _ = monitor._gather(FakeService({"fleet_inventory": ok({"items": [host("A")]})}), S, monitor.get_state())
    assert inputs["previous_fleet"] == []


def test_cron_cli_output_decoded_as_utf8(cron):
    """Hermes prints UTF-8 (box drawing, emoji); Windows' default cp1252 decode crashed and hid the job."""
    monitoring._hermes("list", "--all")
    _, kw = cron.calls[-1]
    assert kw["encoding"] == "utf-8" and kw["errors"] == "replace"
    assert kw["env"]["PYTHONIOENCODING"] == "utf-8" and kw["env"]["PYTHONUTF8"] == "1"


def test_credential_warning_until_passthrough_declared(monkeypatch):
    monkeypatch.setattr(monitoring.config, "env_passthrough", lambda: [])
    warn = monitoring.credential_warnings(svc().settings)
    assert len(warn) == 1 and "SYSADMIN_WINRM_PASSWORD" in warn[0] and "terminal.env_passthrough" in warn[0]
    monkeypatch.setattr(monitoring.config, "env_passthrough", lambda: ["OTHER", "SYSADMIN_WINRM_PASSWORD"])
    assert monitoring.credential_warnings(svc().settings) == []


def test_no_credential_warning_for_hermes_user(monkeypatch):
    monkeypatch.setattr(monitoring.config, "env_passthrough", lambda: [])
    assert monitoring.credential_warnings(svc(transport="local", run_as="hermes_user").settings) == []


def test_enable_preview_and_result_carry_warnings(cron, monkeypatch):
    monkeypatch.setattr(monitoring.config, "env_passthrough", lambda: [])
    op = OPS["monitoring_enable"]
    assert op.local_preview(svc(), {"deliver": "origin", "mode": "watchdog"})["warnings"]
    assert op.local(svc(), {"deliver": "origin", "mode": "watchdog"})["warnings"]


def test_plugin_never_loads_dotenv():
    """Catalog rule 11: credentials come through Hermes. Nothing in the plugin loads or parses .env."""
    root = Path(__file__).resolve().parent.parent
    files = [p for d in ("sysadmin", "scripts") for p in (root / d).rglob("*.py")] + [root / "__init__.py"]
    offenders = [str(p.relative_to(root)) for p in files
                 if "load_hermes_dotenv" in p.read_text(encoding="utf-8") or "dotenv" in p.read_text(encoding="utf-8")]
    assert offenders == []


@pytest.mark.parametrize("op_name,args", [
    ("monitoring_enable", {"deliver": "origin", "mode": "watchdog"}),
    ("monitoring_disable", {}),
])
def test_cron_run_cannot_schedule_cron_jobs(cron, monkeypatch, op_name, args):
    """Hermes's guard against cron jobs scheduling cron jobs holds in every mode."""
    from sysadmin.errors import SysadminError

    monkeypatch.setenv("HERMES_CRON_SESSION", "1")
    monkeypatch.setattr(monitoring.config, "agent_scheduling_allowed", lambda: False)
    op = OPS[op_name]
    calls = len(cron.calls)
    for fn in (op.local, op.local_preview):
        with pytest.raises(SysadminError, match="allow_agent_scheduling"):
            fn(svc(mode="permissive"), args)
    assert len(cron.calls) == calls  # nothing reached `hermes cron`


def test_cron_run_may_schedule_when_hermes_allows_it(cron, monkeypatch):
    monkeypatch.setenv("HERMES_CRON_SESSION", "true")
    monkeypatch.setattr(monitoring.config, "agent_scheduling_allowed", lambda: True)
    assert OPS["monitoring_enable"].local(svc(), {"deliver": "origin", "mode": "watchdog"})["enabled"] is True


def test_chat_and_dashboard_are_not_cron_runs(monkeypatch):
    monkeypatch.delenv("HERMES_CRON_SESSION", raising=False)
    assert monitoring._in_cron_run() is False
    monkeypatch.setenv("HERMES_CRON_SESSION", "0")
    assert monitoring._in_cron_run() is False
