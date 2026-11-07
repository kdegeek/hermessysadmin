import threading
import time

from sysadmin import api, ops  # noqa: F401
from sysadmin.collector import SCHEDULE, Collector
from sysadmin.snapshots import Snapshots


class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


def _wait_idle(snap, key, timeout=2.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not snap._annotate(key, snap._entries[key])["cache"]["refreshing"]:
            return
        time.sleep(0.01)
    raise AssertionError("refresh did not finish")


def test_first_read_waits_then_later_reads_answer_from_the_snapshot():
    clock = Clock()
    snap = Snapshots(clock=clock)
    calls = []
    producer = lambda: calls.append(1) or {"ok": True, "data": len(calls)}
    first = snap.get("k", producer, 60)
    assert first["data"] == 1 and first["cache"]["refreshing"] is False and first["cache"]["age_s"] == 0
    clock.t += 30
    again = snap.get("k", producer, 60)
    assert again["data"] == 1 and again["cache"]["age_s"] == 30 and len(calls) == 1


def test_a_stale_read_answers_at_once_and_refreshes_in_the_background():
    clock = Clock()
    snap = Snapshots(clock=clock)
    gate = threading.Event()
    calls = []

    def producer():
        calls.append(1)
        if len(calls) > 1:
            gate.wait(2)
        return {"ok": True, "data": len(calls)}

    snap.get("k", producer, 60)
    clock.t += 61
    t0 = time.monotonic()
    stale = snap.get("k", producer, 60)
    assert time.monotonic() - t0 < 0.5  # did not wait for the refresh
    assert stale["data"] == 1 and stale["cache"]["refreshing"] is True
    assert snap.get("k", producer, 60)["cache"]["refreshing"] is True  # joins the running refresh
    deadline = time.monotonic() + 2
    while len(calls) < 2 and time.monotonic() < deadline:
        time.sleep(0.01)
    time.sleep(0.05)
    assert len(calls) == 2  # one refresh, shared
    gate.set()
    _wait_idle(snap, "k")
    assert snap.get("k", producer, 60)["data"] == 2


def test_a_failed_refresh_keeps_the_last_good_result_and_reports_the_error():
    clock = Clock()
    snap = Snapshots(clock=clock)
    results = [{"ok": True, "data": "good"}, {"ok": False, "error": {"type": "Timeout", "message": "slow"}}]
    producer = lambda: results.pop(0)
    snap.get("k", producer, 60)
    snap.collect("k", producer)
    out = snap.get("k", producer, 1e9)
    assert out["ok"] is True and out["data"] == "good" and out["cache"]["error"]["type"] == "Timeout"


def test_first_read_failure_is_returned_and_not_stored():
    snap = Snapshots()
    out = snap.get("k", lambda: {"ok": False, "error": {"type": "Timeout"}}, 60)
    assert out == {"ok": False, "error": {"type": "Timeout"}}
    assert snap.peek("k") is None


def test_mark_stale_forces_a_refresh_even_inside_max_age():
    clock = Clock()
    snap = Snapshots(clock=clock)
    calls = []
    producer = lambda: calls.append(1) or {"ok": True, "data": len(calls)}
    snap.get("k", producer, 600)
    clock.t += 1
    snap.mark_stale()
    assert snap.age("k") is None
    snap.get("k", producer, 600)
    _wait_idle(snap, "k")
    assert len(calls) == 2


# ---- the API views ---------------------------------------------------------------------------

def test_device_drawer_answers_from_its_snapshot_and_a_write_marks_it_stale(make_service, runner):
    runner.responses["fleet_device"] = lambda p: {"name": p["ComputerName"], "uptime_days": 1}
    svc = make_service()
    first = api.fleet_device(svc, "PC1")
    assert first["ok"] and first["data"]["name"] == "PC1"
    n = len(runner.calls)
    second = api.fleet_device(svc, "pc1")  # same snapshot, case-insensitive
    assert len(runner.calls) == n and second["cache"]["refreshing"] is False
    svc.invalidate()  # what every write does
    stale = api.fleet_device(svc, "PC1")
    assert stale["data"]["name"] == "PC1" and stale["cache"]["refreshing"] is True
    _wait_idle(api.snapshots(svc), api.device_key("PC1"))
    assert len(runner.calls) == n + 1


def test_fleet_refresh_button_reprobes_in_the_background(make_service, runner):
    runner.responses["fleet_inventory"] = {"items": [], "summary": {}}
    svc = make_service()
    api.fleet(svc)
    n = len(runner.calls)
    out = api.fleet(svc, refresh=True)
    assert out["ok"] and out["cache"]["refreshing"] is True
    _wait_idle(api.snapshots(svc), "fleet")
    assert len(runner.calls) == n + 1


def test_overview_reads_bypass_the_service_cache(make_service, runner):
    for script in ("ad_domain_overview", "ad_dc_health", "rdp_sessions", "gpo_health", "backup_status"):
        runner.responses[script] = {}
    svc = make_service()
    api.overview_now(svc)
    api.overview_now(svc)
    assert sum(1 for c in runner.calls if c[0] == "ad_domain_overview") == 2


# ---- the collector -----------------------------------------------------------------------------

class FakeApi:
    def __init__(self, online):
        self.warmed = []
        self.devices = []
        self.snap = Snapshots()
        self.online = online

    def warm(self, service, what):
        self.warmed.append(what)

    def snapshots(self, service):
        return self.snap

    def online_computers(self, service):
        return list(self.online)

    def device_key(self, name):
        return api.device_key(name)

    def warm_device(self, service, name):
        self.devices.append(name)
        if name != "BAD":
            self.snap.collect(api.device_key(name), lambda: {"ok": True, "data": name})


class Svc:
    class settings:
        configured = True


def test_collector_runs_the_active_schedule_and_sweeps_one_computer_per_pass():
    clock = Clock()
    fake = FakeApi(["PC1", "BAD", "PC2"])
    svc = Svc()
    c = Collector(fake, clock=clock)
    assert c.run_once() == []  # no dashboard request yet: no service to collect for
    c.touch(svc)
    assert c.run_once() == ["health", "overview", "monitoring", "fleet", "devices"]
    assert fake.devices == ["PC1"]
    clock.t += 5
    assert c.run_once() == ["devices"]  # nothing else is due yet; the sweep continues
    clock.t += 5
    c.run_once()
    clock.t += 5
    c.run_once()  # sweep complete: PC1, BAD (failed, not retried), PC2
    assert fake.devices == ["PC1", "BAD", "PC2"]
    clock.t += 5
    assert c.run_once() == []
    clock.t += SCHEDULE["overview"][0]
    assert "overview" in c.run_once()


def test_collector_idles_without_the_device_sweep_and_skips_an_unconfigured_service():
    clock = Clock()
    fake = FakeApi(["PC1"])
    c = Collector(fake, clock=clock)
    c.touch(Svc())
    c._last_activity = float("-inf")  # nobody has used the dashboard for a while: idle schedule
    assert "devices" not in c.run_once()
    assert fake.devices == []

    class Unconfigured:
        class settings:
            configured = False

    c = Collector(fake, clock=clock)
    c.touch(Unconfigured())
    assert c.run_once() == []
