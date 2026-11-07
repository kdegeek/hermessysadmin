import sqlite3
from datetime import datetime, timedelta, timezone

import pytest

from sysadmin import api, commands, fleet
from sysadmin.registry import OPS

NOW = datetime(2026, 11, 6, 12, tzinfo=timezone.utc)


def item(name, **kw):
    base = {"name": name, "online": True, "os": "Windows 11 Enterprise", "c_free_pct": 50, "patch_age_days": 10,
            "pending_reboot": False, "defender_rt": True, "bitlocker": "on", "rdp": False, "nla": True,
            "last_logon": (NOW - timedelta(hours=3)).isoformat()}
    base.update(kw)
    return base


@pytest.fixture(autouse=True)
def _fresh_store():
    fleet.set_store(fleet.FleetStore(sqlite3.connect(":memory:")))
    yield
    fleet.set_store(None)


def test_summary_counts():
    items = [item("A"), item("B", c_free_pct=5, pending_reboot=True), item("C", online=False, last_logon=None),
             item("D", defender_rt=False, bitlocker="off", rdp=True, nla=False, patch_age_days=100, os="Windows 10 Pro")]
    s = fleet.summarize(items, now=NOW, disk_pct=10)
    assert (s["total"], s["online"], s["offline"]) == (4, 3, 1)
    assert s["low_disk"] == 1 and s["pending_reboot"] == 1 and s["defender_off"] == 1
    assert s["bitlocker_off"] == 1 and s["rdp_no_nla"] == 1 and s["patch_compliant"] == 2
    assert s["os_mix"] == {"Windows 11 Enterprise": 3, "Windows 10 Pro": 1}
    assert s["patch_age_buckets"][">90"] == 1 and s["last_seen_buckets"]["never"] == 1


def test_bucket_edges():
    s = fleet.summarize([item("a", patch_age_days=d) for d in (6, 7, 35, 36, 90, 91, None)], now=NOW, disk_pct=10)
    assert s["patch_age_buckets"] == {"<7": 1, "7-35": 2, "35-90": 2, ">90": 1, "unknown": 1}


def test_store_record_dedupes_and_prunes():
    st = fleet.FleetStore(sqlite3.connect(":memory:"))
    old = (NOW - timedelta(days=120)).isoformat()
    assert st.record({"taken_at": old, "summary": {"total": 1}, "items": []})
    assert st.record({"taken_at": NOW.isoformat(), "summary": {"total": 2}, "items": [item("A")]})
    assert not st.record({"taken_at": NOW.isoformat(), "summary": {"total": 2}, "items": []})
    assert st.latest()["summary"]["total"] == 2 and st.previous()["summary"]["total"] == 1
    assert st.prune(90, now=NOW) == 1 and len(st.history(365, now=NOW)) == 1


def test_store_orders_powershell_timestamps():
    st = fleet.FleetStore(sqlite3.connect(":memory:"))
    st.record({"taken_at": "2026-11-05T12:00:00.1234567Z", "summary": {"n": 1}, "items": []})
    st.record({"taken_at": "2026-11-06T12:00:00+00:00", "summary": {"n": 2}, "items": []})
    assert [h["summary"]["n"] for h in st.history(7, now=NOW)] == [1, 2]
    assert st.latest()["summary"]["n"] == 2


def test_inventory_post_records_snapshot(make_service, runner):
    st = fleet.get_store()
    runner.responses["fleet_inventory"] = {"taken_at": NOW.isoformat(), "items": [item("A")]}
    out = make_service().call("fleet_inventory", {}, actor="agent")
    assert out["ok"] and out["data"]["summary"]["total"] == 1 and st.latest() is not None
    make_service().call("fleet_inventory", {}, actor="agent")  # same taken_at: still one row
    assert len(st.history(365, now=NOW)) == 1


def test_inventory_survives_store_failure(make_service, runner, monkeypatch):
    monkeypatch.setattr(fleet, "get_store", lambda: (_ for _ in ()).throw(RuntimeError("disk full")))
    runner.responses["fleet_inventory"] = {"taken_at": NOW.isoformat(), "items": [item("A")]}
    assert make_service().call("fleet_inventory", {}, actor="agent")["ok"]


def test_history_op_and_api(make_service):
    st = fleet.get_store()
    st.record({"taken_at": datetime.now(timezone.utc).isoformat(), "summary": {"total": 3}, "items": []})
    svc = make_service()
    assert api.fleet_history(svc, 30)["data"]["items"][0]["summary"]["total"] == 3
    assert api.fleet_history(svc, 91)["ok"] is False


def test_api_fleet_and_device(make_service, runner):
    runner.responses["fleet_inventory"] = {"taken_at": NOW.isoformat(), "items": [item("A")]}
    runner.responses["fleet_device"] = {"name": "A", "admins": []}
    svc = make_service()
    assert api.fleet(svc, refresh=True)["data"]["summary"]["total"] == 1
    assert api.fleet_device(svc, "A")["data"]["name"] == "A"
    assert runner.calls[-1][1] == {"ComputerName": "A"}


def test_ad_fleet_command(make_service, runner, monkeypatch):
    runner.responses["fleet_inventory"] = {"taken_at": NOW.isoformat(), "items": [
        item("A", user="CORP\\amy"), item("B", online=False, c_free_pct=None), item("C", patch_age_days=80, pending_reboot=True)]}
    svc = make_service()
    run = lambda arg: commands._fleet(svc, [arg] if arg else [], None, "")  # noqa: E731
    assert "3 computer(s)" in run("").splitlines()[0] and len(run("").splitlines()) == 4
    assert [l.split(" · ")[0] for l in run("offline").splitlines()[1:]] == ["B"]
    assert [l.split(" · ")[0] for l in run("patch").splitlines()[1:]] == ["C"]
    assert "reboot" in run("reboot").splitlines()[1]
    assert [l.split(" · ")[0] for l in run("amy").splitlines()[1:]] == ["A"]
    assert "fleet" in commands.USAGE


def test_ops_are_read_only():
    assert all(OPS[n].tier == "R" for n in ("fleet_inventory", "fleet_device", "fleet_history"))


def test_snapshots_are_kept_per_kind():
    st = fleet.FleetStore(sqlite3.connect(":memory:"))
    st.record({"taken_at": "2026-11-05T12:00:00+00:00", "summary": {"n": 1}, "items": [], "kind": "workstation"})
    st.record({"taken_at": "2026-11-05T13:00:00+00:00", "summary": {"n": 9}, "items": [], "kind": "any"})
    st.record({"taken_at": "2026-11-06T12:00:00+00:00", "summary": {"n": 2}, "items": []})  # default kind
    assert [h["summary"]["n"] for h in st.history(7, now=NOW, kind="workstation")] == [1, 2]
    assert [h["summary"]["n"] for h in st.history(7, now=NOW, kind="any")] == [9]
    assert st.previous(kind="workstation")["summary"]["n"] == 1 and st.previous(kind="any") is None
    assert st.latest(kind="any")["summary"]["n"] == 9


def test_store_migrates_database_without_kind_column():
    conn = sqlite3.connect(":memory:")
    conn.execute("CREATE TABLE snapshots (taken_at TEXT PRIMARY KEY, summary TEXT, items TEXT)")
    conn.execute("INSERT INTO snapshots VALUES ('2026-11-05T12:00:00+00:00', '{\"n\": 1}', '[]')")
    conn.commit()
    st = fleet.FleetStore(conn)
    assert [h["summary"]["n"] for h in st.history(7, now=NOW, kind="workstation")] == [1]
    assert st.history(7, now=NOW, kind="any") == []
    assert st.record({"taken_at": NOW.isoformat(), "summary": {"n": 2}, "items": [], "kind": "any"})
    fleet.FleetStore(conn)  # re-opening an already migrated database is a no-op


def test_inventory_records_kind_and_skips_ou_runs(make_service, runner):
    st = fleet.get_store()
    runner.responses["fleet_inventory"] = {"taken_at": NOW.isoformat(), "items": [item("A")]}
    make_service().call("fleet_inventory", {"ou": "OU=Lab,DC=corp,DC=local"}, actor="agent")
    assert st.latest() is None
    runner.responses["fleet_inventory"] = {"taken_at": (NOW + timedelta(minutes=1)).isoformat(), "items": [item("A")]}
    make_service().call("fleet_inventory", {"kind": "any", "refresh": True}, actor="agent")
    assert st.latest(kind="any") is not None and st.latest(kind="workstation") is None


def test_history_op_filters_by_kind(make_service):
    st = fleet.get_store()
    now = datetime.now(timezone.utc)
    st.record({"taken_at": now.isoformat(), "summary": {"total": 3}, "items": []})
    st.record({"taken_at": (now - timedelta(hours=1)).isoformat(), "summary": {"total": 30}, "items": [], "kind": "any"})
    svc = make_service()
    assert [h["summary"]["total"] for h in api.fleet_history(svc, 30)["data"]["items"]] == [3]
