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

    for name in ("health", "test_connection", "list_ops", "decision", "preview", "run_op", "overview", "audit", "refresh"):
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
