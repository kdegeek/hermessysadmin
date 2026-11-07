"""Dashboard API logic. Every function returns {"ok": ...} and never raises."""

from __future__ import annotations

import logging
import threading
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Callable, Mapping

from . import __version__, ops  # noqa: F401  (registers every op)
from . import catalog as _catalog
from .ops.catalog_ops import entry_detail
from .errors import ApprovalRequired, InvalidArguments, error_result
from .registry import OPS, Op, coerce_args, schema_for, target_of
from .snapshots import Snapshots

log = logging.getLogger(__name__)
ACTOR = "dashboard"

# Dashboard reads are served from snapshots (see snapshots.py): a view answers instantly from the
# last result and refreshes in the background once it is older than this many seconds. Opening a
# device drawer therefore shows what was last collected and refreshes it if it is over a minute old.
MAX_AGE = {"health": 60, "overview": 60, "fleet": 300, "monitoring": 60, "device": 60, "remote_check": 60, "sessions": 20}
_snap_lock = threading.Lock()


def snapshots(service: Any) -> Snapshots:
    """The snapshot store for this service (one per service; a write marks it stale)."""
    snap = getattr(service, "_hs_snapshots", None)
    if snap is None:
        with _snap_lock:
            snap = getattr(service, "_hs_snapshots", None)
            if snap is None:
                snap = Snapshots()
                service._hs_snapshots = snap
                if hasattr(service, "on_invalidate"):
                    service.on_invalidate(snap.mark_stale)
    return snap


def _read(service: Any, name: str, args: Mapping[str, Any] | None = None) -> dict[str, Any]:
    """A fresh read for a snapshot: skips the service read cache (the snapshot is the cache here)."""
    return service.call(name, dict(args or {}), actor=ACTOR, fresh=True)


def _view(service: Any, key: str, producer: Callable[[], dict[str, Any]], max_age: float, *, refresh: bool = False) -> dict[str, Any]:
    return snapshots(service).get(key, lambda: _safe(producer), max_age, refresh=refresh)


def device_key(computer: str) -> str:
    return "device:" + str(computer).strip().lower()


def remote_check_key(computer: str) -> str:
    return "remote_check:" + str(computer).strip().lower()


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


def _health_now(service: Any) -> dict[str, Any]:
    s = service.settings
    data: dict[str, Any] = {
        "configured": s.configured, "host": s.host, "mode": s.mode, "version": __version__,
        "transport": s.transport, "run_as": s.run_as if s.transport == "local" else None,
        "run_as_user": s.username if s.transport == "local" and s.run_as == "account" else None,
        "escape_enabled": s.enable_powershell_escape, "stale_days": s.backup_stale_days,
        "status": "unconfigured", "error": None,
    }
    if s.configured:
        r = _read(service, "ad_dc_health")
        data["status"] = r["data"]["status"] if r["ok"] else "bad"
        data["error"] = None if r["ok"] else r["error"]
    return {"ok": True, "data": data}


def health(service: Any) -> dict[str, Any]:
    if not service.settings.configured:
        return _safe(lambda: _health_now(service))  # nothing remote to wait for; the setup card updates at once
    return _view(service, "health", lambda: _health_now(service), MAX_AGE["health"])


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


def catalog(service: Any = None) -> dict[str, Any]:
    def go() -> dict[str, Any]:
        ops = _catalog.entries()
        counts: dict[str, int] = {}
        for op in ops:
            counts[op.meta["category"]] = counts.get(op.meta["category"], 0) + 1
        return {"ok": True, "data": {
            "categories": [{"name": c, "count": counts[c]} for c in _catalog.CATEGORIES if c in counts],
            "items": [entry_detail(op) for op in ops],
        }}

    return _safe(go)


def decision(service: Any, name: str, body: Mapping[str, Any] | None) -> dict[str, Any]:
    def go() -> dict[str, Any]:
        op = _op(name)
        args = _args(body)
        d = service.decision(name, args)
        clean = coerce_args(op, args)
        return {"ok": True, "data": {
            "action": d.action, "tier": d.tier, "reason": d.reason, "needs_preview": d.needs_preview,
            "can_preview": bool(op.preview),
            "target": target_of(op, clean), "confirm_name": confirm_name_of(op, clean),
            "type_to_confirm": d.action == "approve" and op.destructive,
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
                    type_to_confirm=op.destructive,
                )
            if op.destructive:
                typed = str((body or {}).get("confirm_name") or "").strip().lower()
                if typed != expected.lower():
                    raise InvalidArguments(f"Type '{expected}' to confirm this destructive change.", confirm_name=expected)
        return service.call(name, args, actor=ACTOR, session=session, approved=d.tier if d.action == "approve" else False)

    return _safe(go)


OVERVIEW_SECTIONS = {
    "domain": "ad_domain_overview", "dc_health": "ad_dc_health", "sessions": "rdp_sessions",
    "gpo_health": "gpo_health", "backups": "backup_status",
}


def overview(service: Any) -> dict[str, Any]:
    return _view(service, "overview", lambda: overview_now(service), MAX_AGE["overview"])


def overview_now(service: Any) -> dict[str, Any]:
    """Collect the overview: its five reads run side by side (each on its own PowerShell worker)."""
    def go() -> dict[str, Any]:
        with ThreadPoolExecutor(max_workers=len(OVERVIEW_SECTIONS), thread_name_prefix="hermes-sysadmin-overview") as pool:
            futures = {key: pool.submit(_read, service, name) for key, name in OVERVIEW_SECTIONS.items()}
            sections = {key: f.result() for key, f in futures.items()}

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
            "backups_ok": bk.get("ok"),
            "backups_total": bk.get("hosts"),
            "gpos_unlinked": gpo.get("unlinked"),
            "users_enabled": counts.get("users_enabled"),
            "users_never_expire": counts.get("users_never_expire"),
            "users_stale": counts.get("users_stale"),
            "oldest_system_state": bk.get("oldest_system_state"),
            "dc_status": data("dc_health").get("status") or "unknown",
        }
        return {"ok": True, "data": {
            "kpis": kpis,
            "domain": data("domain") or None,
            "dcs": data("dc_health") or None,
            "backups": [{"host": h.get("host"), "age_hours": h.get("age_hours"), "state": h.get("state")}
                        for h in data("backups").get("items") or []],
            "audit": service.audit.query(limit=10),
            "errors": {k: r["error"] for k, r in sections.items() if not r["ok"]},
        }}

    return _safe(go)


def audit(service: Any, limit: int = 100, actor: str | None = None, decision: str | None = None) -> dict[str, Any]:
    return _safe(lambda: {"ok": True, "data": {"items": service.audit.query(limit=limit, actor=actor or None, decision=decision or None)}})


def fleet(service: Any, refresh: bool = False) -> dict[str, Any]:
    """The inventory snapshot; refresh=True (the Refresh button) re-probes in the background."""
    return _view(service, "fleet", lambda: _read(service, "fleet_inventory"), MAX_AGE["fleet"], refresh=refresh)


def fleet_device(service: Any, computer: str) -> dict[str, Any]:
    return _view(service, device_key(computer), lambda: _read(service, "fleet_device", {"computer": computer}), MAX_AGE["device"])


def fleet_history(service: Any, days: int = 30) -> dict[str, Any]:
    return _safe(lambda: service.call("fleet_history", {"days": days}, actor=ACTOR))


def remote_check(service: Any, computer: str) -> dict[str, Any]:
    return _view(service, remote_check_key(computer), lambda: _read(service, "remote_access_check", {"computer": computer}), MAX_AGE["remote_check"])


def remote_sessions(service: Any, computers: list[str] | None = None) -> dict[str, Any]:
    names = list(computers or [])
    key = "sessions:" + ",".join(sorted(n.strip().lower() for n in names))
    return _view(service, key, lambda: _read(service, "remote_sessions", {"computers": names}), MAX_AGE["sessions"])


def remote_shadow(service: Any, computer: str, session_id: int, control: bool = True, consent: bool = True) -> dict[str, Any]:
    args = {"computer": computer, "session_id": session_id, "control": control, "consent": consent}
    return _safe(lambda: service.call("remote_shadow_command", args, actor=ACTOR))


def remote_assist(service: Any, computer: str) -> dict[str, Any]:
    return _safe(lambda: service.call("remote_assist_command", {"computer": computer}, actor=ACTOR))


def monitoring(service: Any) -> dict[str, Any]:
    return _view(service, "monitoring", lambda: _read(service, "monitoring_status"), MAX_AGE["monitoring"])


# ---- background collection (collector.py) -------------------------------------------------

def warm(service: Any, what: str) -> dict[str, Any]:
    """Collect one dashboard view now (the background collector). what: health|overview|fleet|monitoring."""
    producers = {
        "health": lambda: _health_now(service),
        "overview": lambda: overview_now(service),
        "fleet": lambda: _read(service, "fleet_inventory"),
        "monitoring": lambda: _read(service, "monitoring_status"),
    }
    return snapshots(service).collect(what, lambda: _safe(producers[what]))


def warm_device(service: Any, computer: str) -> None:
    """Collect one computer's drawer (device detail and remote access checks)."""
    snap = snapshots(service)
    snap.collect(device_key(computer), lambda: _safe(lambda: _read(service, "fleet_device", {"computer": computer})))
    snap.collect(remote_check_key(computer), lambda: _safe(lambda: _read(service, "remote_access_check", {"computer": computer})))


def online_computers(service: Any) -> list[str]:
    """Online computers in the last fleet snapshot (the device sweep's work list)."""
    res = snapshots(service).peek("fleet") or {}
    items = ((res.get("data") or {}).get("items") or []) if res.get("ok") else []
    return [str(i["name"]) for i in items if i.get("online") and i.get("name")]


def monitoring_enable(service: Any, body: Mapping[str, Any] | None) -> dict[str, Any]:
    return run_op(service, "monitoring_enable", body)


def monitoring_disable(service: Any, body: Mapping[str, Any] | None) -> dict[str, Any]:
    return run_op(service, "monitoring_disable", body)


def refresh(service: Any) -> dict[str, Any]:
    def go() -> dict[str, Any]:
        service.invalidate()
        return {"ok": True, "data": {"refreshed": True}}

    return _safe(go)
