"""Remote access to desktops: sessions, shadow and Remote Assistance command builders, access checks."""

from __future__ import annotations

import re
from typing import Any, Mapping

from ..errors import InvalidArguments
from ..registry import Op, Param, register
from .rdp import _clean, parse_quser

TOOLSET = "remote"
_HOST = re.compile(r"[A-Za-z0-9][A-Za-z0-9.-]{0,252}")
COMPUTER = Param("computer", "string", "Computer name or DNS name.", required=True, ps="ComputerName")


def _host(host: Any) -> str:
    text = host if isinstance(host, str) else ""
    if not _HOST.fullmatch(text):
        raise InvalidArguments("'computer' must be a plain computer name or DNS name.")
    return text


def shadow_command(host: str, session_id: int, control: bool = True, consent: bool = True) -> str:
    host = _host(host)
    if isinstance(session_id, bool) or not isinstance(session_id, int) or session_id < 0:
        raise InvalidArguments("'session_id' must be an integer >= 0.")
    return f"mstsc.exe /shadow:{session_id} /v:{host}" + (" /control" if control else "") + ("" if consent else " /noConsentPrompt")


def assist_command(host: str) -> str:
    return f"msra.exe /offerRA {_host(host)}"


def cmd_file(command: str, note: str) -> str:
    return f"@echo off\r\nrem {_clean(note)}\r\n{command}\r\n"


def _shadow(service: Any, args: Mapping[str, Any]) -> Any:
    host = _host(args.get("computer"))
    sid = args["session_id"]
    command = shadow_command(host, sid, args.get("control", True), args.get("consent", True))
    return {
        "command": command,
        "cmd_file": cmd_file(command, f"Shadow session {sid} on {host}"),
        "filename": f"shadow-{host}-{sid}.cmd",
        "note": (
            "Shadowing needs the endpoint's shadow policy to allow it (remote.set_shadow_policy) and RDP reachability. "
            "Run the .cmd on your admin PC."
        ),
    }


def _assist(service: Any, args: Mapping[str, Any]) -> Any:
    host = _host(args.get("computer"))
    command = assist_command(host)
    return {
        "command": command,
        "cmd_file": cmd_file(command, f"Offer Remote Assistance to {host}"),
        "filename": f"assist-{host}.cmd",
        "note": (
            "Needs Remote Assistance enabled (remote.enable_remote_assistance). "
            "For Quick Assist, the user opens Quick Assist and reads you the code; nothing is needed here."
        ),
    }


def _post_sessions(data: Any, args: Mapping[str, Any], settings: Any) -> Any:
    data = data or {}
    items: list[dict[str, Any]] = []
    for row in data.get("items") or []:
        lines = row.get("lines") or []
        if isinstance(lines, str):
            lines = [lines]
        items += [{"host": row.get("host", ""), **s} for s in parse_quser(list(lines))]
    summary = dict(data.get("summary") or {})
    summary["sessions"] = len(items)
    return {"items": items, "errors": list(data.get("errors") or []), "summary": summary}


_CHECKS = (
    ("rdp_enabled", "Remote Desktop enabled", "rdp_enabled", "remote.enable_rdp"),
    ("nla", "Network Level Authentication required", "nla", "remote.set_nla"),
    ("rdp_firewall", "Remote Desktop firewall rules enabled", "rdp_firewall", "remote.open_rdp_firewall"),
    ("rdp_users", "Remote Desktop Users members", "rdp_users", "remote.add_rdp_user"),
    ("shadow_policy", "Shadow policy allows shadowing", "shadow", "remote.set_shadow_policy"),
    ("ra_unsolicited", "Offer Remote Assistance allowed", "ra_unsolicited", "remote.enable_remote_assistance"),
    ("ra_firewall", "Remote Assistance firewall rules enabled", "ra_firewall", "remote.enable_remote_assistance"),
)


def access_rows(raw: Mapping[str, Any]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for key, label, field, fix in _CHECKS:
        value = raw.get(field)
        if key == "rdp_users":
            if value is None:
                value = []
            elif not isinstance(value, list):
                value = [value]
            ok = None
        elif key == "shadow_policy":
            value = value if isinstance(value, int) and not isinstance(value, bool) else None
            ok = value is not None and 1 <= value <= 4
        else:
            ok = value if isinstance(value, bool) else None
        rows.append({"key": key, "label": label, "ok": ok, "value": value, "fix": fix})
    return rows


def _post_check(data: Any, args: Mapping[str, Any], settings: Any) -> Any:
    return {"checks": access_rows(data or {})}


def _shadow_escalate(args: Mapping[str, Any], settings: Any, facts: Any) -> bool:
    # Shadowing without a consent prompt lets an admin watch a user who does not know.
    return args.get("consent") is False


register(Op(
    name="remote_shadow_command", toolset=TOOLSET, tier="R", script="", local=_shadow, escalate=_shadow_escalate,
    description=(
        "Build the mstsc /shadow command (and a .cmd file) to watch or control a user's session on a computer. "
        "Setting consent=false skips the user's consent prompt and needs approval."
    ),
    params=(
        COMPUTER,
        Param("session_id", "integer", "Session ID from remote_sessions.", required=True, minimum=0),
        Param("control", "boolean", "Take control, not just view.", default=True),
        Param("consent", "boolean", "Ask the user for consent first.", default=True),
    ),
))

register(Op(
    name="remote_assist_command", toolset=TOOLSET, tier="R", script="", local=_assist,
    description="Build the msra /offerRA command (and a .cmd file) to offer Remote Assistance to a computer.",
    params=(COMPUTER,),
))

register(Op(
    name="remote_sessions", toolset=TOOLSET, tier="R", script="remote_sessions",
    description="Who is logged on (quser) across desktops: user, session id, state and idle time per host.",
    params=(
        Param("computers", "array", "Computer names. Omit for every enabled workstation.", ps="Computers"),
        Param("ou", "string", "DN of an OU whose enabled computers to include.", ps="Ou"),
    ),
    post=_post_sessions, cache_ttl=30,
))

register(Op(
    name="remote_access_check", toolset=TOOLSET, tier="R", script="remote_access_check",
    description=(
        "Check what remote access to one computer needs: RDP, NLA, firewall, Remote Desktop Users, shadow policy "
        "and Remote Assistance. Each failing check names the catalog entry that fixes it."
    ),
    params=(COMPUTER,),
    post=_post_check,
))
