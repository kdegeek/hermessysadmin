"""pre_tool_call escalates writes to Hermes's human-approval gate; post_tool_call audits denials."""

from __future__ import annotations

import json
import logging
import uuid
from typing import Any

from . import catalog, runtime
from .audit import redact
from .errors import InvalidArguments
from .policy import decide
from .registry import OPS, coerce_args, target_of

log = logging.getLogger(__name__)
PREFIX = "[hermes-sysadmin]"


PREVIEW_LIMIT = 1500


def _clip(text: str, limit: int | None) -> str:
    if limit is None or len(text) <= limit:
        return text
    return text[:limit] + f"\n  [TRUNCATED: {len(text) - limit} more characters not shown]"


def format_preview(data: Any, limit: int | None = PREVIEW_LIMIT) -> str:
    """Human-readable approval text. Secrets are redacted; truncation is always marked."""
    data = redact(data) if isinstance(data, dict) else data
    if not isinstance(data, dict):
        return _clip(json.dumps(data, default=str), limit)
    lines: list[str] = []
    if data.get("summary"):
        lines.append(str(data["summary"]))
    for change in data.get("changes") or []:
        lines.append(f"  • {change}")
    current = data.get("current")
    if isinstance(current, dict):
        for key, value in current.items():
            shown = ", ".join(map(str, value)) if isinstance(value, list) else value
            lines.append(f"  {key}: {shown}")
    if data.get("details"):
        lines.append("  " + json.dumps(data["details"], default=str))
    return _clip("\n".join(lines), limit)


def pre_tool_call(tool_name: str = "", args: dict | None = None, **kwargs: Any) -> dict | None:
    if tool_name == "catalog_run":
        try:
            name, merged = catalog.run_target(args)
        except InvalidArguments:
            return None  # the handler reports bad arguments
        op = OPS[name]
        title = (op.meta or {}).get("title", "")
        return _gate(op, merged, f"catalog {(op.meta or {}).get('id')} ({title})", tool_name)
    op = OPS.get(tool_name)
    if op is None:
        return None
    return _gate(op, args, op.name, tool_name)


def _gate(op: Any, raw_args: dict | None, display: str, tool_name: str) -> dict | None:
    if op.tier == "R" and op.escalate is None:
        return None
    try:
        service = runtime.get_service()
        try:
            clean = coerce_args(op, raw_args)
        except InvalidArguments:
            return None
        decision = decide(op, clean, service.settings, service.facts)
        if decision.action != "approve":
            return None
        label = "HIGH-RISK" if decision.tier == "H" else "Write"
        lines = [f"{PREFIX} {label}: {display} → {target_of(op, clean) or '(no target)'}", decision.reason]
        if decision.needs_preview:
            preview = service.preview(op.name, clean)
            error = (preview.get("error") or {}).get("message", "unknown error")
            body = format_preview(preview.get("data")) if preview.get("ok") else f"unavailable — {error}"
            lines.append("Preview (no change made yet):\n" + body)
        else:
            # No preview: the human must see every argument they approve, untruncated.
            lines.append("Arguments:\n" + format_preview({"details": redact(clean)}, limit=None))
        # Only the WinRM transport holds a service credential; on the local transport HermesCred is $null.
        if (op.name == "ad_powershell" and service.settings.transport == "winrm"
                and "hermescred" in str(clean.get("script", "")).lower()):
            lines.append("⚠ This script references the service credential ($Global:HermesCred).")
        rule_key = (
            f"hermes-sysadmin:{op.name}"
            if decision.tier == "W"
            else f"hermes-sysadmin:{op.name}:once:{uuid.uuid4().hex}"
        )
        return {"action": "approve", "message": "\n".join(lines), "rule_key": rule_key}
    except Exception as exc:
        log.exception("hermes-sysadmin: pre_tool_call failed for %s", tool_name)
        return {
            "action": "approve",
            "message": f"{PREFIX} {tool_name}: the safety policy could not evaluate this call ({type(exc).__name__}). "
                       "Approve only if you intended this change.",
            "rule_key": f"hermes-sysadmin:{tool_name}:once:{uuid.uuid4().hex}",
        }


def post_tool_call(tool_name: str = "", args: dict | None = None, result: Any = None, status: str = "", **kwargs: Any) -> None:
    if str(status).lower() != "blocked":
        return None
    try:
        if tool_name == "catalog_run":
            try:
                tool_name, args = catalog.run_target(args)
            except InvalidArguments:
                return None  # bad id: nothing ran and nothing to attribute the denial to
        elif tool_name not in OPS:
            return None
        reason = str(result or "").strip()[:160] or "by user"
        runtime.get_service().record_denied(
            tool_name, args, actor="agent", session=str(kwargs.get("session_id") or ""), reason=reason
        )
    except Exception:
        log.exception("hermes-sysadmin: post_tool_call audit failed")
    return None
