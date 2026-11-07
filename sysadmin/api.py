"""Dashboard API logic. Every function returns {"ok": ...} and never raises."""

from __future__ import annotations

import logging
from typing import Any, Callable, Mapping

from . import __version__, ops  # noqa: F401  (registers every op)
from . import catalog as _catalog
from .ops.catalog_ops import entry_detail
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
    return _safe(lambda: service.call("fleet_inventory", {"refresh": refresh}, actor=ACTOR))


def fleet_device(service: Any, computer: str) -> dict[str, Any]:
    return _safe(lambda: service.call("fleet_device", {"computer": computer}, actor=ACTOR))


def fleet_history(service: Any, days: int = 30) -> dict[str, Any]:
    return _safe(lambda: service.call("fleet_history", {"days": days}, actor=ACTOR))


def remote_check(service: Any, computer: str) -> dict[str, Any]:
    return _safe(lambda: service.call("remote_access_check", {"computer": computer}, actor=ACTOR))


def remote_sessions(service: Any, computers: list[str] | None = None) -> dict[str, Any]:
    return _safe(lambda: service.call("remote_sessions", {"computers": computers or []}, actor=ACTOR))


def remote_shadow(service: Any, computer: str, session_id: int, control: bool = True, consent: bool = True) -> dict[str, Any]:
    args = {"computer": computer, "session_id": session_id, "control": control, "consent": consent}
    return _safe(lambda: service.call("remote_shadow_command", args, actor=ACTOR))


def remote_assist(service: Any, computer: str) -> dict[str, Any]:
    return _safe(lambda: service.call("remote_assist_command", {"computer": computer}, actor=ACTOR))


def monitoring(service: Any) -> dict[str, Any]:
    return _safe(lambda: service.call("monitoring_status", {}, actor=ACTOR))


def monitoring_enable(service: Any, body: Mapping[str, Any] | None) -> dict[str, Any]:
    return run_op(service, "monitoring_enable", body)


def monitoring_disable(service: Any, body: Mapping[str, Any] | None) -> dict[str, Any]:
    return run_op(service, "monitoring_disable", body)


def refresh(service: Any) -> dict[str, Any]:
    def go() -> dict[str, Any]:
        service.invalidate()
        return {"ok": True, "data": {"refreshed": True}}

    return _safe(go)
