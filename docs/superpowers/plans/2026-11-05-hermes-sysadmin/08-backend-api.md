# Phase 8 — Dashboard backend API

> Part of the [Hermes Sysadmin plan](README.md). Requires Phases 1–7.

**Deliverable:** A FastAPI router mounted at `/api/plugins/hermes-sysadmin/`. Every dashboard action goes through `Service.call()` with `actor="dashboard"`. A generic `/ops/{name}` route replaces the per-resource routes sketched in the spec, so the backend never drifts from the op registry. The route enforces the **confirm contract**:

- R ops run.
- W ops need `confirm: true`.
- H ops also need `confirm_name` to match the object the user was asked to type.
- Blocks are audited once by `Service.call`.

Every response is HTTP 200 with `{ok, data}` or `{ok: false, error}`, so the Desktop page has one error path.

| Route | Purpose |
|---|---|
| `GET /health` | configured?, host, mode, version, escape enabled, stale days, DC status (`ok`/`warn`/`bad`/`unconfigured`) |
| `POST /test-connection` | drops caches and runs `ad_connection_test` |
| `GET /ops` | op catalog: name, toolset, tier, preview, description, params |
| `POST /ops/{name}/decision` | `{action, tier, reason, needs_preview, target, confirm_name}` for the dialog |
| `POST /ops/{name}/preview` | WhatIf-style preview (`Service.preview`) |
| `POST /ops/{name}` | run with the confirm contract; body `{args, confirm?, confirm_name?}` |
| `GET /overview` | KPI tiles + domain + DC health + last 10 audit rows; per-section errors |
| `GET /audit` | `?limit=&actor=&decision=` |
| `POST /refresh` | drop the snapshot cache |

The logic lives in `sysadmin/api.py`, a set of plain functions that are unit-tested with the Phase 1 fakes. `dashboard/plugin_api.py` is a thin router. Hermes imports it standalone with `spec_from_file_location`, so the router loads the `sysadmin` package by path under the private name `hermes_sysadmin_core`.

---

### Task 1: API functions

**Files:**
- Create: `sysadmin/api.py`
- Test: `tests/test_api.py`

**Interfaces:**
- Consumes: `Service.call/decision/preview/invalidate`, `Service.audit.query`, `Service.settings`, `OPS`, `coerce_args`, `target_of`, `schema_for`, `error_result`, `__version__`.
- Produces:
  - `health(service) -> dict`, `test_connection(service) -> dict`, `list_ops() -> dict`, `confirm_name_of(op, args) -> str`.
  - `decision(service, name, body) -> dict`, `preview(service, name, body) -> dict`, `run_op(service, name, body) -> dict`.
  - `overview(service) -> dict`, `audit(service, limit, actor, decision) -> dict`, `refresh(service) -> dict`.
  - Every function returns `{"ok": bool, ...}` and never raises.
  - Overview `data`: `{kpis: {users, users_disabled, users_locked, passwords_expiring, computers, computers_stale, gpos, gpos_needing_attention, rdp_sessions, rdp_active, backups_bad, oldest_system_state, dc_status}, domain, dcs, audit, errors: {section: error}}`.

- [ ] **Step 1: Write the failing test** — `tests/test_api.py`

```python
from dataclasses import replace

from sysadmin import api, ops  # noqa: F401
from sysadmin.config import Settings
from sysadmin.errors import ConnectionFailed
from sysadmin.registry import OPS

DC = {
    "name": "DC01", "site": "HQ", "reachable": True,
    "services": {"NTDS": "Running", "Netlogon": "Running", "KDC": "Running", "DNS": "Running", "W32Time": "Running"},
    "sysvol_shared": True, "netlogon_shared": True, "time_skew_seconds": 0.2, "replication": {"failures": 0},
}


def test_list_ops_is_the_registry():
    out = api.list_ops()
    names = [o["name"] for o in out["data"]["items"]]
    assert names == sorted(n for n in OPS if not n.startswith("t_"))
    unlock = next(o for o in out["data"]["items"] if o["name"] == "ad_user_unlock")
    assert unlock["tier"] == "W" and unlock["params"][0]["name"] == "identity"


def test_reads_run_without_confirm(make_service, runner, audit):
    runner.responses["ad_search"] = {"items": []}
    assert api.run_op(make_service(), "ad_search", {"args": {"query": "bob"}}) == {"ok": True, "data": {"items": []}}
    assert audit.query() == []


def test_write_without_confirm_is_refused_and_not_run(make_service, runner):
    out = api.run_op(make_service(), "ad_user_unlock", {"args": {"identity": "bob"}})
    assert out["ok"] is False and out["error"]["type"] == "ApprovalRequired"
    assert out["error"]["tier"] == "W" and out["error"]["confirm_name"] == "bob"
    assert runner.calls == []


def test_confirmed_write_runs_and_audits_as_dashboard(make_service, runner, audit):
    out = api.run_op(make_service(), "ad_user_unlock", {"args": {"identity": "bob"}, "confirm": True})
    assert out["ok"] is True
    row = audit.query(limit=1)[0]
    assert (row["actor"], row["decision"]) == ("dashboard", "confirmed")


def test_high_risk_needs_matching_typed_name(make_service, runner):
    svc = make_service()
    body = {"args": {"identity": "bob"}, "confirm": True, "confirm_name": "bobby"}
    out = api.run_op(svc, "ad_user_delete", body)
    assert out["error"]["type"] == "InvalidArguments" and runner.calls == []
    assert api.run_op(svc, "ad_user_delete", {**body, "confirm_name": "  BOB "})["ok"] is True


def test_blocked_write_is_audited_once(make_service, audit):
    out = api.run_op(make_service(), "ad_user_unlock", {"args": {"identity": "krbtgt"}, "confirm": True})
    assert out["error"]["type"] == "PolicyBlocked"
    assert [r["decision"][:8] for r in audit.query()] == ["blocked:"]


def test_permissive_mode_runs_writes_without_confirm(make_service, settings):
    svc = make_service(settings=replace(settings, mode="permissive"))
    assert api.run_op(svc, "ad_user_unlock", {"args": {"identity": "bob"}})["ok"] is True


def test_decision_describes_the_dialog(make_service):
    out = api.decision(make_service(), "ad_user_delete", {"args": {"identity": "bob"}})
    assert out["data"] == {
        "action": "approve", "tier": "H", "reason": "High-risk change: requires approval with a preview.",
        "needs_preview": True, "target": "bob", "confirm_name": "bob",
    }


def test_confirm_name_choice():
    assert api.confirm_name_of(OPS["gpo_link"], {"identity": "Screen Lock", "target": "OU=Fin,DC=corp"}) == "Screen Lock"
    assert api.confirm_name_of(OPS["ad_group_add_member"], {"group": "Domain Admins", "members": ["bob"]}) == "Domain Admins"
    assert api.confirm_name_of(OPS["rdp_set_enabled"], {"hosts": ["DC01", "DC02"], "enabled": False}) == "DC01"
    assert api.confirm_name_of(OPS["ad_powershell"], {"script": "Get-Date", "reason": "r"}) == "ad_powershell"


def test_preview_passes_through(make_service, runner):
    runner.responses["ad_user_delete"] = lambda p: {"summary": "Delete bob", "preview": p.get("Preview")}
    out = api.preview(make_service(), "ad_user_delete", {"args": {"identity": "bob"}})
    assert out == {"ok": True, "data": {"summary": "Delete bob", "preview": True}}


def test_unknown_op_and_bad_args_are_errors(make_service):
    svc = make_service()
    assert api.run_op(svc, "nope", {})["error"]["type"] == "InvalidArguments"
    assert api.decision(svc, "ad_user_unlock", {"args": {}})["error"]["type"] == "InvalidArguments"
    assert api.run_op(svc, "ad_user_unlock", {"args": "bob"})["error"]["type"] == "InvalidArguments"


def test_overview_builds_kpis_and_reports_section_errors(make_service, runner):
    runner.responses.update({
        "ad_domain_overview": {"domain": "corp.example.local", "counts": {
            "users": 1240, "users_disabled": 88, "users_locked": 3, "passwords_expiring": 17,
            "computers": 410, "computers_stale": 22, "gpos": 41}},
        "ad_dc_health": {"items": [DC], "errors": []},
        "rdp_sessions": {"hosts": [{"host": "SRV1", "lines": [" alice  rdp-tcp#2  2  Active  .  11/4/2026 8:01 AM"]}], "errors": []},
        "gpo_list": {"items": [{"name": "Old", "status": "AllSettingsEnabled", "links": [],
                                "user_version": {"ad": 1, "sysvol": 1}, "computer_version": {"ad": 1, "sysvol": 1}}]},
        "backup_status": ConnectionFailed("SRV-FS01 unreachable"),
    })
    out = api.overview(make_service())
    k = out["data"]["kpis"]
    assert (k["users"], k["users_locked"], k["gpos_needing_attention"], k["rdp_active"], k["dc_status"]) == (1240, 3, 1, 1, "ok")
    assert k["oldest_system_state"] is None and k["backups_bad"] is None
    assert out["data"]["errors"]["backups"]["type"] == "ConnectionError"
    assert out["data"]["domain"]["domain"] == "corp.example.local"


def test_health_unconfigured_makes_no_remote_call(make_service, runner):
    out = api.health(make_service(settings=Settings()))
    assert out["data"]["configured"] is False and out["data"]["status"] == "unconfigured"
    assert runner.calls == []


def test_health_configured_reports_dc_status(make_service, runner):
    runner.responses["ad_dc_health"] = {"items": [{**DC, "reachable": False}], "errors": []}
    d = api.health(make_service())["data"]
    assert (d["configured"], d["status"], d["host"], d["mode"]) == (True, "bad", "dc01.corp.example.local", "strict")


def test_audit_and_refresh(make_service, audit):
    audit.record(actor="dashboard", session="", tool="ad_user_unlock", target="bob", tier="W",
                 decision="confirmed", result="ok", params={})
    svc = make_service()
    assert api.audit(svc, limit=10, actor="dashboard", decision=None)["data"]["items"][0]["target"] == "bob"
    assert api.refresh(svc) == {"ok": True, "data": {"refreshed": True}}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_api.py`
Expected: FAIL — `ImportError: cannot import name 'api'`

- [ ] **Step 3: Implement** — `sysadmin/api.py`

```python
"""Dashboard API logic. Every function returns {"ok": ...} and never raises."""

from __future__ import annotations

import logging
from typing import Any, Callable, Mapping

from . import __version__, ops  # noqa: F401  (registers every op)
from .errors import ApprovalRequired, InvalidArguments, error_result
from .registry import OPS, Op, coerce_args, schema_for, target_of

log = logging.getLogger(__name__)
ACTOR = "dashboard"


def _safe(fn: Callable[[], dict[str, Any]]) -> dict[str, Any]:
    try:
        return fn()
    except Exception as exc:  # SysadminError → typed error; anything else → InternalError
        if not hasattr(exc, "to_dict"):
            log.exception("hermes-sysadmin: dashboard API error")
        return error_result(exc)


def _args(body: Mapping[str, Any] | None) -> dict[str, Any]:
    args = (body or {}).get("args") or {}
    if not isinstance(args, dict):
        raise InvalidArguments("'args' must be an object.")
    return args


def _op(name: str) -> Op:
    op = OPS.get(name)
    if op is None or name.startswith("t_"):
        raise InvalidArguments(f"Unknown operation '{name}'.")
    return op


def confirm_name_of(op: Op, args: Mapping[str, Any]) -> str:
    """The text a user must type to confirm a high-risk change."""
    keys = list(op.identities) + [p.name for p in op.params if p.required and p.name not in ("script", "reason")]
    for key in keys:
        value = args.get(key)
        if isinstance(value, list):
            value = value[0] if value else None
        if isinstance(value, str) and value.strip():
            return value.strip()
    return op.name


def health(service: Any) -> dict[str, Any]:
    def go() -> dict[str, Any]:
        s = service.settings
        data: dict[str, Any] = {
            "configured": s.configured, "host": s.host, "mode": s.mode, "version": __version__,
            "escape_enabled": s.enable_powershell_escape, "stale_days": s.backup_stale_days,
            "status": "unconfigured", "error": None,
        }
        if s.configured:
            r = service.call("ad_dc_health", {}, actor=ACTOR)
            data["status"] = r["data"]["status"] if r["ok"] else "bad"
            data["error"] = None if r["ok"] else r["error"]
        return {"ok": True, "data": data}

    return _safe(go)


def test_connection(service: Any) -> dict[str, Any]:
    def go() -> dict[str, Any]:
        service.invalidate()
        return service.call("ad_connection_test", {}, actor=ACTOR)

    return _safe(go)


def list_ops() -> dict[str, Any]:
    def go() -> dict[str, Any]:
        items = []
        for op in sorted(OPS.values(), key=lambda o: o.name):
            if op.name.startswith("t_"):
                continue
            props = schema_for(op)["parameters"]["properties"]
            items.append({
                "name": op.name, "toolset": op.toolset, "tier": op.tier, "preview": op.preview,
                "description": op.description,
                "params": [{"name": p.name, "required": p.required, **props[p.name]} for p in op.params],
            })
        return {"ok": True, "data": {"items": items}}

    return _safe(go)


def decision(service: Any, name: str, body: Mapping[str, Any] | None) -> dict[str, Any]:
    def go() -> dict[str, Any]:
        op = _op(name)
        args = _args(body)
        d = service.decision(name, args)
        clean = coerce_args(op, args)
        return {"ok": True, "data": {
            "action": d.action, "tier": d.tier, "reason": d.reason, "needs_preview": d.needs_preview,
            "target": target_of(op, clean), "confirm_name": confirm_name_of(op, clean),
        }}

    return _safe(go)


def preview(service: Any, name: str, body: Mapping[str, Any] | None) -> dict[str, Any]:
    def go() -> dict[str, Any]:
        _op(name)
        return service.preview(name, _args(body))

    return _safe(go)


def run_op(service: Any, name: str, body: Mapping[str, Any] | None) -> dict[str, Any]:
    def go() -> dict[str, Any]:
        op = _op(name)
        args = _args(body)
        session = str((body or {}).get("session") or "")
        d = service.decision(name, args)
        if d.action == "block":
            return service.call(name, args, actor=ACTOR, session=session)  # audits the block once
        if d.action == "approve":
            clean = coerce_args(op, args)
            expected = confirm_name_of(op, clean)
            if (body or {}).get("confirm") is not True:
                raise ApprovalRequired(
                    f"{name} must be confirmed in the dashboard dialog.",
                    hint="Send confirm: true after the user approves.",
                    tier=d.tier, needs_preview=d.needs_preview, confirm_name=expected,
                )
            if d.tier == "H":
                typed = str((body or {}).get("confirm_name") or "").strip().lower()
                if typed != expected.lower():
                    raise InvalidArguments(f"Type '{expected}' to confirm this high-risk change.", confirm_name=expected)
        return service.call(name, args, actor=ACTOR, session=session, approved=d.action == "approve")

    return _safe(go)


def overview(service: Any) -> dict[str, Any]:
    def go() -> dict[str, Any]:
        sections = {
            "domain": service.call("ad_domain_overview", {}, actor=ACTOR),
            "dc_health": service.call("ad_dc_health", {}, actor=ACTOR),
            "sessions": service.call("rdp_sessions", {}, actor=ACTOR),
            "gpo_health": service.call("gpo_health", {}, actor=ACTOR),
            "backups": service.call("backup_status", {}, actor=ACTOR),
        }

        def data(key: str) -> dict[str, Any]:
            r = sections[key]
            return (r.get("data") or {}) if r["ok"] else {}

        counts = data("domain").get("counts") or {}
        gpo = data("gpo_health").get("summary") or {}
        rdp = data("sessions").get("summary") or {}
        bk = data("backups").get("summary") or {}
        kpis = {
            **{k: counts.get(k) for k in ("users", "users_disabled", "users_locked", "passwords_expiring",
                                          "computers", "computers_stale", "gpos")},
            "gpos_needing_attention": gpo.get("needs_attention"),
            "rdp_sessions": rdp.get("sessions"),
            "rdp_active": rdp.get("active"),
            "backups_bad": bk.get("bad"),
            "oldest_system_state": bk.get("oldest_system_state"),
            "dc_status": data("dc_health").get("status") or "unknown",
        }
        return {"ok": True, "data": {
            "kpis": kpis,
            "domain": data("domain") or None,
            "dcs": data("dc_health") or None,
            "audit": service.audit.query(limit=10),
            "errors": {k: r["error"] for k, r in sections.items() if not r["ok"]},
        }}

    return _safe(go)


def audit(service: Any, limit: int = 100, actor: str | None = None, decision: str | None = None) -> dict[str, Any]:
    return _safe(lambda: {"ok": True, "data": {"items": service.audit.query(limit=limit, actor=actor or None, decision=decision or None)}})


def refresh(service: Any) -> dict[str, Any]:
    def go() -> dict[str, Any]:
        service.invalidate()
        return {"ok": True, "data": {"refreshed": True}}

    return _safe(go)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.venv/bin/pytest tests/test_api.py`
Expected: `15 passed`

- [ ] **Step 5: Commit**

```bash
git add sysadmin/api.py tests/test_api.py
git commit -m "feat: dashboard API logic with confirm contract

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: FastAPI router and dashboard manifest

**Files:**
- Create: `dashboard/manifest.json`, `dashboard/plugin_api.py`
- Test: `tests/test_plugin_api.py`

**Interfaces:**
- Consumes: `sysadmin.api.*` and `sysadmin.runtime.get_service`, imported by path as `hermes_sysadmin_core.api` / `hermes_sysadmin_core.runtime`.
- Produces: `router` (FastAPI `APIRouter`) with the routes in the table at the top. Phase 9 calls them with `ctx.rest(path, {method, body, timeoutMs})`.

- [ ] **Step 1: Write the failing test** — `tests/test_plugin_api.py`

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_plugin_api.py`
Expected: FAIL — `FileNotFoundError: ... dashboard/plugin_api.py`

- [ ] **Step 3: Implement**

`dashboard/manifest.json`:
```json
{
  "name": "hermes-sysadmin",
  "label": "Active Directory",
  "tab": { "hidden": true },
  "api": "plugin_api.py"
}
```

`dashboard/plugin_api.py`:
```python
"""hermes-sysadmin dashboard backend, mounted by Hermes at /api/plugins/hermes-sysadmin/.

Hermes imports this file standalone (spec_from_file_location), so the plugin's `sysadmin`
package is loaded by path under a private module name. All handlers are async and run the
blocking WinRM work in a worker thread so the gateway event loop never stalls. Every route
returns HTTP 200 with {"ok": true, "data": ...} or {"ok": false, "error": {...}}.
"""

from __future__ import annotations

import asyncio
import importlib
import importlib.util
import sys
from pathlib import Path
from typing import Any, Optional

from fastapi import APIRouter, Body, Query

_ROOT = Path(__file__).resolve().parent.parent
_CORE = "hermes_sysadmin_core"


def _load_core() -> None:
    if _CORE in sys.modules:
        return
    pkg_dir = _ROOT / "sysadmin"
    spec = importlib.util.spec_from_file_location(_CORE, pkg_dir / "__init__.py", submodule_search_locations=[str(pkg_dir)])
    module = importlib.util.module_from_spec(spec)
    sys.modules[_CORE] = module
    spec.loader.exec_module(module)


_load_core()
_api = importlib.import_module(f"{_CORE}.api")
_runtime = importlib.import_module(f"{_CORE}.runtime")
_errors = importlib.import_module(f"{_CORE}.errors")

router = APIRouter()


async def _with_service(fn_name: str, *args: Any, **kwargs: Any) -> dict[str, Any]:
    def work() -> dict[str, Any]:
        try:
            service = _runtime.get_service()
        except Exception as exc:  # never surface a 500 to the Desktop page
            return _errors.error_result(exc)
        return getattr(_api, fn_name)(service, *args, **kwargs)

    return await asyncio.to_thread(work)


@router.get("/health")
async def health() -> dict[str, Any]:
    return await _with_service("health")


@router.post("/test-connection")
async def test_connection() -> dict[str, Any]:
    return await _with_service("test_connection")


@router.get("/ops")
async def list_ops() -> dict[str, Any]:
    return await asyncio.to_thread(_api.list_ops)


@router.post("/ops/{name}/decision")
async def op_decision(name: str, body: Optional[dict] = Body(default=None)) -> dict[str, Any]:
    return await _with_service("decision", name, body or {})


@router.post("/ops/{name}/preview")
async def op_preview(name: str, body: Optional[dict] = Body(default=None)) -> dict[str, Any]:
    return await _with_service("preview", name, body or {})


@router.post("/ops/{name}")
async def op_run(name: str, body: Optional[dict] = Body(default=None)) -> dict[str, Any]:
    return await _with_service("run_op", name, body or {})


@router.get("/overview")
async def overview() -> dict[str, Any]:
    return await _with_service("overview")


@router.get("/audit")
async def audit(
    limit: int = Query(100, ge=1, le=1000),
    actor: Optional[str] = None,
    decision: Optional[str] = None,
) -> dict[str, Any]:
    return await _with_service("audit", limit=limit, actor=actor, decision=decision)


@router.post("/refresh")
async def refresh() -> dict[str, Any]:
    return await _with_service("refresh")
```

- [ ] **Step 4: Run tests**

Run: `.venv/bin/pytest`
Expected: all pass (`tests/test_plugin_api.py`: 13 passed).

- [ ] **Step 5: Exercise it in a running Hermes**

```bash
hermes plugins enable hermes-sysadmin
hermes gateway restart          # backend routes mount at startup
PORT=$(hermes dashboard --print-port 2>/dev/null || echo 9119)
curl -s "http://127.0.0.1:$PORT/api/plugins/hermes-sysadmin/health" | jq .
curl -s "http://127.0.0.1:$PORT/api/plugins/hermes-sysadmin/overview" | jq . | head -40
curl -s -X POST "http://127.0.0.1:$PORT/api/plugins/hermes-sysadmin/ops/ad_user_unlock" \
  -H 'content-type: application/json' -d '{"args":{"identity":"zz-hermes-test-1"}}' | jq .
```
Expected:
- `/health` shows `"configured": true` and a DC `status`.
- `/overview` returns `kpis`.
- The unlock without `confirm` returns `"type": "ApprovalRequired"` with `confirm_name`.

If the port or command differs on this Hermes build, run `hermes dashboard --help` and use the dashboard URL it prints. The local dashboard API may require the session token header that Hermes Desktop adds automatically. If curl gets 401, skip this step; Phase 9 exercises the same routes through Desktop.

- [ ] **Step 6: Commit**

```bash
git add dashboard tests/test_plugin_api.py
git commit -m "feat: dashboard FastAPI router

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
