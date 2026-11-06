"""Windows Server Backup operations."""

from __future__ import annotations

import re
from datetime import datetime, timezone
from typing import Any, Mapping

from ..registry import Op, Param, register

TOOLSET = "ad_backup"
HOSTS = Param("hosts", "array", "Computer DNS names. Omit both hosts and ou to check every enabled server.")
OU = Param("ou", "string", "DN of an OU whose enabled computers to include.")
HOST = Param("host", "string", "Computer DNS name.", required=True, ps="ComputerName")
_FRACTION = re.compile(r"(\.\d{6})\d+")
_OUTCOMES = {1: "started", 4: "succeeded", 14: "completed"}


def parse_iso(text: Any) -> datetime | None:
    if not isinstance(text, str) or not text:
        return None
    try:
        value = datetime.fromisoformat(_FRACTION.sub(r"\1", text).replace("Z", "+00:00"))
    except ValueError:
        return None
    return value if value.tzinfo else value.replace(tzinfo=timezone.utc)


def backup_state(host: Mapping[str, Any], stale_days: int, now: datetime) -> dict[str, Any]:
    taken = parse_iso(host.get("last_system_state"))
    age = round((now - taken).total_seconds() / 3600, 1) if taken else None
    out: dict[str, Any] = {"state": "ok", "stale": False, "age_hours": age, "message": ""}
    if not host.get("installed"):
        return {**out, "state": "none", "message": "Windows Server Backup feature not installed"}
    if (host.get("job") or {}).get("running"):
        return {**out, "state": "run"}
    if not host.get("policy") and not host.get("versions"):
        return {**out, "state": "none", "message": "No backup policy configured"}
    hr = int(host.get("last_result_hr") or 0)
    if hr != 0:
        return {**out, "state": "bad", "message": str(host.get("message") or "").strip() or f"Last backup failed (0x{hr & 0xFFFFFFFF:08X})"}
    if taken is None:
        return {**out, "state": "bad", "stale": True, "message": "No system-state backup found"}
    if age is not None and age > stale_days * 24:
        return {**out, "state": "bad", "stale": True, "message": f"System-state backup is {round(age / 24, 1)} days old"}
    return out


def event_outcome(event: Mapping[str, Any]) -> str:
    outcome = _OUTCOMES.get(int(event.get("id") or 0))
    if outcome:
        return outcome
    return "failed" if str(event.get("level", "")).lower() in ("error", "critical") else "info"


def _search_base(settings: Any) -> dict[str, Any]:
    return {"ServerSearchBase": settings.server_search_base}


def _post_status(data: Any, args: Mapping[str, Any], settings: Any) -> Any:
    now = datetime.now(timezone.utc)
    return status_summary(data, settings.backup_stale_days, now)


def status_summary(data: Any, stale_days: int, now: datetime) -> dict[str, Any]:
    data = data or {}
    items = [{**h, **backup_state(h, stale_days, now)} for h in data.get("results") or []]
    errors = list(data.get("errors") or [])
    aged = [h for h in items if h["age_hours"] is not None]
    oldest = max(aged, key=lambda h: h["age_hours"]) if aged else None
    return {
        "items": items,
        "errors": errors,
        "stale_days": stale_days,
        "summary": {
            "hosts": len(items) + len(errors),
            "ok": sum(1 for h in items if h["state"] == "ok"),
            "bad": sum(1 for h in items if h["state"] == "bad"),
            "running": sum(1 for h in items if h["state"] == "run"),
            "not_configured": sum(1 for h in items if h["state"] == "none"),
            "unreachable": len(errors),
            "oldest_system_state": {"host": oldest["host"], "age_hours": oldest["age_hours"]} if oldest else None,
        },
    }


def _post_jobs(data: Any, args: Mapping[str, Any], settings: Any) -> Any:
    data = dict(data or {})
    data["history"] = [{**e, "outcome": event_outcome(e)} for e in data.get("history") or []]
    return data


register(Op(
    name="backup_status", toolset=TOOLSET, tier="R", script="backup_status",
    description=(
        "Windows Server Backup status per host: feature installed, policy, last success, last system-state backup, "
        "next run, versions, running job. Flags hosts whose system state is older than backup_stale_days."
    ),
    params=(HOSTS, OU), post=_post_status, inject=_search_base, cache_ttl=60,
))

register(Op(
    name="backup_versions", toolset=TOOLSET, tier="R", script="backup_versions",
    description="Backup versions available on a host (newest first): time, target and what each can recover.",
    params=(HOST,),
))

register(Op(
    name="backup_jobs", toolset=TOOLSET, tier="R", script="backup_jobs",
    description="The running backup job on a host (operation, percent) and recent backup events (started/succeeded/failed).",
    params=(HOST,), post=_post_jobs,
))

register(Op(
    name="backup_start", toolset=TOOLSET, tier="W", script="backup_start",
    description=(
        "Start a one-off backup as a server-side job and return immediately; poll backup_jobs for progress. "
        "kind: system_state (default), policy (run the scheduled policy now), volumes (give 'volumes'). "
        "target: volume (E:) or UNC share; defaults to the scheduled policy's target."
    ),
    params=(
        HOST,
        Param("kind", "string", "What to back up.", enum=("system_state", "policy", "volumes"), default="system_state"),
        Param("target", "string", "Backup target: a volume like E: or a share like \\\\NAS01\\wsb\\SRV1."),
        Param("volumes", "array", "Volumes for kind=volumes, e.g. C:, D:."),
    ),
    target=lambda a: f"{a.get('host', '')} ({str(a.get('kind', 'system_state')).replace('_', ' ')})",
))

register(Op(
    name="backup_cancel", toolset=TOOLSET, tier="W", script="backup_cancel",
    description="Cancel the backup job running on a host.",
    params=(HOST,),
))

register(Op(
    name="backup_set_policy", toolset=TOOLSET, tier="H", script="backup_set_policy",
    description=(
        "Replace a host's scheduled backup policy: daily times (HH:mm), target (volume or UNC share), "
        "system state, bare-metal recovery and volumes. The preview shows current vs new."
    ),
    params=(
        HOST,
        Param("schedule", "array", "Daily start times, e.g. 23:00.", required=True),
        Param("target", "string", "Target volume (E:) or UNC share.", required=True),
        Param("system_state", "boolean", "Include system state.", default=True),
        Param("bare_metal", "boolean", "Include bare-metal recovery.", default=False),
        Param("volumes", "array", "Extra volumes to include, e.g. D:."),
    ),
    preview=True,
))
