"""scripts/verify_live.py stays read-only and covers the v0.2 surface. Never talks to a live system here."""

import importlib.util
import json
from pathlib import Path

from sysadmin import catalog, ops  # noqa: F401
from sysadmin.config import Settings
from sysadmin.registry import OPS

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "verify_live.py"
spec = importlib.util.spec_from_file_location("verify_live", SCRIPT)
vl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vl)

CTX = {"dc": "dc01.corp.example.local", "domain": "corp.example.local", "ws": "WS01"}


def test_samples_for_the_documented_entries():
    get = lambda i: vl.catalog_sample_params(OPS["cat." + i], CTX)
    assert get("network.test_port") == {"computers": ["WS01"], "Target": CTX["dc"], "Port": 389}
    assert get("events.search") == {"computers": ["WS01"], "Log": "System", "Id": 6005}
    assert get("dns.stale_records") == {"Zone": "corp.example.local"}
    assert get("dhcp.leases_for_host") == {"Name": "WS01"}
    assert get("endpoint.installed_software") == {"computers": ["WS01"]}
    assert get("files.ntfs_access")["Server"] == CTX["dc"]
    assert get("ad.replication_summary") == {}


def test_every_read_entry_gets_samples_covering_its_required_params_or_none():
    reads = [e for e in catalog.entries() if e.tier == "R"]
    assert reads
    for e in reads:
        params = vl.catalog_sample_params(e, CTX)
        assert params is not None, f"{e.name} would be skipped as NoSample"
        assert {p.name for p in e.params if p.required} <= set(params)
        assert ("computers" in params) == (e.meta["target"] == "endpoint")


def test_missing_context_means_no_sample_not_a_guess():
    assert vl.catalog_sample_params(OPS["cat.dns.stale_records"], {**CTX, "domain": None}) is None
    assert vl.catalog_sample_params(OPS["cat.dhcp.leases_for_host"], {**CTX, "ws": None}) is None


def test_first_online_workstation():
    inv = {"items": [{"name": "A", "online": False}, {"name": "B", "online": True}, {"name": "C", "online": True}]}
    assert vl.first_online_workstation(inv) == "B"
    assert vl.first_online_workstation({"items": []}) is None


def test_script_has_no_module_install_and_no_direct_writes():
    text = SCRIPT.read_text(encoding="utf-8")
    assert "catalog_module_install" not in text


class _FakeService:
    calls: list = []
    previews: list = []

    def __init__(self, settings, runner, audit):
        self.settings = settings

    def call(self, name, args, actor="command", **kw):
        assert OPS[name].tier == "R", f"non-read op {name} called"
        assert self.settings.mode == "read-only"
        _FakeService.calls.append(name)
        if name == "cat.dhcp.scope_utilization":
            return {"ok": False, "error": {"type": "NotInstalled", "message": "DhcpServer"}}
        if name == "cat.dns.zones":
            return {"ok": False, "error": {"type": "RemoteScriptError", "message": "boom"}}
        if name == "ad_dc_list":
            return {"ok": True, "data": {"items": [{"name": "dc01.corp.example.local"}]}}
        if name == "fleet_inventory":
            return {"ok": True, "data": {"items": [{"name": "WS01", "online": True}]}}
        return {"ok": True, "data": {"items": []}}

    def preview(self, name, args):
        _FakeService.previews.append(name)
        return {"ok": True, "data": {"summary": "x", "changes": []}}


class _FakeTransport:
    made: list = []

    def __init__(self, *a):
        pass

    def close(self):
        pass


def test_main_counts_ok_skip_err_and_exits_nonzero_only_on_err(monkeypatch, tmp_path, capsys):
    settings = Settings(host="dc01.corp.example.local", username="CORP\\svc", password="pw")
    monkeypatch.setattr(vl, "load_settings", lambda: settings)
    monkeypatch.setattr(vl, "make_transport", lambda s: _FakeTransport.made.append(s) or _FakeTransport())
    monkeypatch.setattr(vl, "Service", _FakeService)
    monkeypatch.setattr(vl, "Runner", lambda t: t)
    out = tmp_path / "r.json"
    assert vl.main(["--out", str(out)]) == 1  # cat.dns.zones is an ERR
    rows = json.loads(out.read_text())
    status = {r["op"]: r["status"] for r in rows}
    assert status["cat.dhcp.scope_utilization"] == "SKIP" and status["cat.dns.zones"] == "ERR"
    assert {"fleet_device", "remote_sessions", "remote_access_check", "fleet_history", "catalog_module_status",
            "monitoring_status"} <= set(status)
    assert {"cat.remote.set_nla", "cat.maint.gpupdate", "cat.remote.restart_computer", "monitoring_enable"} <= set(_FakeService.previews)
    assert all(OPS[r["op"]].tier == "R" for r in rows if r["mode"] == "read")
    assert " SKIP / 1 ERR of " in capsys.readouterr().out


def test_main_uses_runtime_transport_selection_and_prints_it(monkeypatch, capsys):
    settings = Settings(transport="local", run_as="account", username="CORP\\svc", password="pw-secret-1")
    _FakeTransport.made.clear()
    monkeypatch.setattr(vl, "load_settings", lambda: settings)
    monkeypatch.setattr(vl, "make_transport", lambda s: _FakeTransport.made.append(s) or _FakeTransport())
    monkeypatch.setattr(vl, "Service", _FakeService)
    monkeypatch.setattr(vl, "Runner", lambda t: t)
    vl.main([])
    out = capsys.readouterr().out
    assert _FakeTransport.made and _FakeTransport.made[0].mode == "read-only"
    assert _FakeTransport.made[0].transport == "local"
    assert "transport=local run_as=account" in out and "CORP\\svc" in out
    assert "pw-secret-1" not in out


def test_script_selects_transport_through_runtime():
    text = SCRIPT.read_text(encoding="utf-8")
    assert "from sysadmin.runtime import make_transport" in text and "PsrpTransport" not in text
