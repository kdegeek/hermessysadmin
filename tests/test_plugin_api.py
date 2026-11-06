import importlib.util
import sys
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parent.parent


class StubService:
    def __init__(self):
        self.calls = []


@pytest.fixture
def client(monkeypatch):
    spec = importlib.util.spec_from_file_location("hermes_dashboard_plugin_hermes-sysadmin", ROOT / "dashboard" / "plugin_api.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    core_api = sys.modules["hermes_sysadmin_core.api"]
    seen = []

    def fake(fn_name):
        def f(*args, **kwargs):
            seen.append((fn_name, args[1:], kwargs))  # args[0] is the service
            return {"ok": True, "data": {"fn": fn_name}}
        return f

    for name in ("health", "test_connection", "list_ops", "decision", "preview", "run_op", "overview", "audit", "refresh", "fleet", "fleet_device", "fleet_history"):
        monkeypatch.setattr(core_api, name, fake(name))
    monkeypatch.setattr(sys.modules["hermes_sysadmin_core.runtime"], "get_service", lambda: StubService())
    app = FastAPI()
    app.include_router(mod.router, prefix="/api/plugins/hermes-sysadmin")
    return TestClient(app), seen


def test_manifest():
    import json

    m = json.loads((ROOT / "dashboard" / "manifest.json").read_text(encoding="utf-8"))
    assert m == {"name": "hermes-sysadmin", "label": "Active Directory", "tab": {"hidden": True}, "api": "plugin_api.py"}


@pytest.mark.parametrize(
    "method, path, fn",
    [
        ("get", "/health", "health"),
        ("post", "/test-connection", "test_connection"),
        ("get", "/ops", "list_ops"),
        ("post", "/ops/ad_user_unlock/decision", "decision"),
        ("post", "/ops/ad_user_unlock/preview", "preview"),
        ("post", "/ops/ad_user_unlock", "run_op"),
        ("get", "/overview", "overview"),
        ("get", "/audit?limit=5&actor=agent", "audit"),
        ("post", "/refresh", "refresh"),
        ("get", "/fleet?refresh=true", "fleet"),
        ("get", "/fleet/history?days=7", "fleet_history"),
        ("get", "/fleet/PC-01", "fleet_device"),
    ],
)
def test_routes_delegate(client, method, path, fn):
    http, seen = client
    kwargs = {"json": {"args": {"identity": "bob"}, "confirm": True}} if method == "post" else {}
    r = getattr(http, method)("/api/plugins/hermes-sysadmin" + path, **kwargs)
    assert r.status_code == 200 and r.json() == {"ok": True, "data": {"fn": fn}}
    assert seen[-1][0] == fn


def test_run_op_receives_name_and_body(client):
    http, seen = client
    http.post("/api/plugins/hermes-sysadmin/ops/ad_user_unlock", json={"args": {"identity": "bob"}, "confirm": True})
    assert seen[-1][1] == ("ad_user_unlock", {"args": {"identity": "bob"}, "confirm": True})


def test_audit_query_params(client):
    http, seen = client
    http.get("/api/plugins/hermes-sysadmin/audit?limit=5&actor=agent&decision=denied")
    assert seen[-1][2] == {"limit": 5, "actor": "agent", "decision": "denied"}


def test_post_without_body_is_ok(client):
    http, seen = client
    assert http.post("/api/plugins/hermes-sysadmin/ops/ad_search").json()["ok"] is True
    assert seen[-1][1] == ("ad_search", {})


P = "/api/plugins/hermes-sysadmin"


@pytest.mark.parametrize("content", [b"{not json", b"[1, 2]", b'"x"', b""])
def test_bad_bodies_are_treated_as_empty(client, content):
    c, seen = client
    r = c.post(f"{P}/ops/ad_user_unlock", content=content, headers={"content-type": "application/json"})
    assert r.status_code == 200 and seen[-1] == ("run_op", ("ad_user_unlock", {}), {})


@pytest.mark.parametrize("raw, expected", [("abc", 100), ("0", 1), ("5000", 1000), ("25", 25)])
def test_audit_limit_is_clamped_not_rejected(client, raw, expected):
    c, seen = client
    assert c.get(f"{P}/audit", params={"limit": raw}).status_code == 200
    assert seen[-1][2]["limit"] == expected


def test_unexpected_api_exception_is_an_ok_false_200(client, monkeypatch):
    c, _ = client

    def boom(*a, **k):
        raise RuntimeError("kaput")

    monkeypatch.setattr(sys.modules["hermes_sysadmin_core.api"], "overview", boom)
    r = c.get(f"{P}/overview")
    assert r.status_code == 200 and r.json()["ok"] is False
