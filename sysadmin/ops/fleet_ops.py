"""Fleet inventory (every AD computer, probed over WinRM), device detail and snapshot history."""

from __future__ import annotations

import logging
from datetime import datetime, timezone
from typing import Any, Mapping

from .. import fleet
from ..registry import Op, Param, register

TOOLSET = "fleet"
log = logging.getLogger(__name__)


def _search_base(settings: Any) -> dict[str, Any]:
    return {"ServerSearchBase": settings.server_search_base}


def _post_inventory(data: Any, args: Mapping[str, Any], settings: Any) -> Any:
    data = data or {}
    items = sorted(data.get("items") or [], key=lambda i: str(i.get("name", "")).lower())
    now = datetime.now(timezone.utc)
    taken_at = str(data.get("taken_at") or now.isoformat())
    summary = fleet.summarize(items, now=now, disk_pct=int(getattr(settings, "alert_disk_free_pct", 10)))
    # Only whole-fleet runs are snapshots: an OU run is a subset and would corrupt trends and offline diffs.
    # Each snapshot carries its kind (workstation|server|any) and history/previous are filtered by it.
    if not args.get("ou"):
        try:
            store = fleet.get_store()
            store.record({"taken_at": taken_at, "summary": summary, "items": items, "kind": str(args.get("kind") or "workstation")})
            store.prune(90)
        except Exception:
            log.exception("hermes-sysadmin: fleet snapshot store failed")
    return {"items": items, "summary": summary, "taken_at": taken_at}


def _history(service: Any, args: Mapping[str, Any]) -> Any:
    return {"items": fleet.get_store().history(int(args.get("days") or 30), kind=str(args.get("kind") or "workstation"))}


register(Op(
    name="fleet_inventory", toolset=TOOLSET, tier="R", script="fleet_inventory",
    description=(
        "Fleet inventory: every enabled AD computer with online state, OS, last logon, disk, uptime, pending reboot, "
        "patch age, Defender, BitLocker and RDP/NLA posture, plus a summary. Each whole-fleet run (no ou) is saved as a snapshot of its kind."
    ),
    params=(
        Param("ou", "string", "DN of an OU to limit the inventory to."),
        Param("kind", "string", "Which computers to include.", enum=("workstation", "server", "any"), default="workstation"),
        Param("refresh", "boolean", "Bypass the 10 minute cache and probe now."),
    ),
    post=_post_inventory, inject=_search_base, cache_ttl=600,
))

register(Op(
    name="fleet_device", toolset=TOOLSET, tier="R", script="fleet_device",
    description=(
        "Detail for one computer: inventory fields plus local administrators, top CPU and memory processes, "
        "stopped automatic services, errors from the last 24 hours and installed software count."
    ),
    params=(Param("computer", "string", "Computer name or DNS name.", required=True, ps="ComputerName"),),
))

register(Op(
    name="fleet_history", toolset=TOOLSET, tier="R", script="",
    description="Fleet summary snapshots over time (oldest first), from earlier fleet_inventory runs.",
    params=(
        Param("days", "integer", "How many days back (1-90).", default=30, minimum=1, maximum=90),
        Param("kind", "string", "Which snapshots: the Overview trend uses workstation (the default).",
              enum=("workstation", "server", "any"), default="workstation"),
    ),
    local=_history,
))
