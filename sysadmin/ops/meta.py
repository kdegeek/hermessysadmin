"""Escape hatch and audit-log tools. Both run in Python (Op.local) rather than as a fixed script."""

from __future__ import annotations

from typing import Any, Mapping

from ..errors import InvalidArguments
from ..registry import Op, Param, register

TOOLSET = "ad_meta"
MAX_SCRIPT = 20000


def _run_powershell(service: Any, args: Mapping[str, Any]) -> Any:
    script = str(args.get("script") or "")
    if len(script) > MAX_SCRIPT:
        raise InvalidArguments(f"Script is longer than {MAX_SCRIPT} characters.")
    # The only place in the plugin where text is executed as code. It is reached only after
    # policy (enabled + H-tier approval with the full script shown) and is always audited.
    return service.runner.run_text("Invoke-Op {\n" + script + "\n}", {})


def _audit_log(service: Any, args: Mapping[str, Any]) -> Any:
    return {
        "items": service.audit.query(
            limit=int(args.get("limit") or 50),
            actor=args.get("actor") or None,
            decision=args.get("decision") or None,
        )
    }


register(Op(
    name="ad_powershell", toolset=TOOLSET, tier="H", destructive=True, script="",
    description=(
        "LAST RESORT: run arbitrary PowerShell on the jump-host domain controller (ActiveDirectory and GroupPolicy "
        "modules loaded; Get-HermesFanout available). Prefer a typed tool whenever one exists. Every call needs "
        "approval and is audited. Return a hashtable; it is serialised as JSON."
    ),
    params=(
        Param("script", "string", "PowerShell to run. The last value it outputs is returned.", required=True),
        Param("reason", "string", "Why no typed tool fits; shown in the approval and audit log.", required=True),
    ),
    target=lambda a: str(a.get("reason", ""))[:120],
    local=_run_powershell,
    enabled=lambda s: bool(s.enable_powershell_escape),
))

register(Op(
    name="sysadmin_audit_log", toolset=TOOLSET, tier="R", script="",
    description="Recent changes made through hermes-sysadmin (who, what, target, tier, decision, result), newest first.",
    params=(
        Param("limit", "integer", "Rows to return.", default=50, minimum=1),
        Param("actor", "string", "Only this actor.", enum=("agent", "dashboard", "command")),
        Param("decision", "string", "Decision prefix, e.g. 'denied', 'blocked', 'approved'."),
    ),
    local=_audit_log,
))
