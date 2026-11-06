"""Remote Desktop operations."""

from __future__ import annotations

import re
from typing import Any, Mapping
from urllib.parse import quote

from ..policy import is_domain_controller_name
from ..registry import Op, Param, register

TOOLSET = "ad_rdp"
HOSTS = Param("hosts", "array", "Computer DNS names. Omit both hosts and ou to scan every enabled server.")
HOSTS_REQUIRED = Param("hosts", "array", "Computer DNS names.", required=True)
OU = Param("ou", "string", "DN of an OU whose enabled computers to include.")
HOST = Param("host", "string", "Computer DNS name.", required=True, ps="ComputerName")
SESSION = Param("session_id", "integer", "Session ID from rdp_sessions.", required=True, minimum=0)
MEMBERS = Param("members", "array", "Users or groups (sAMAccountName or DOMAIN\\name).", required=True)

_QUSER = re.compile(r"^[\s>]*(\S+)\s+(?:(\S+)\s+)?(\d+)\s+(\S+)\s+(\S+)\s+(.+?)\s*$")
_STATES = {"active": "active", "disc": "disconnected"}


def _search_base(settings: Any) -> dict[str, Any]:
    return {"ServerSearchBase": settings.server_search_base}


def idle_minutes(text: str) -> int | None:
    t = text.strip().lower()
    if t in ("", ".", "none"):
        return 0
    try:
        days = 0
        if "+" in t:
            d, t = t.split("+", 1)
            days = int(d)
        if ":" in t:
            h, m = t.split(":", 1)
            return days * 1440 + int(h) * 60 + int(m)
        return days * 1440 + int(t)
    except ValueError:
        return None


def parse_quser(lines: list[str]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for line in lines:
        text = str(line).rstrip()
        if not text.strip() or text.strip().upper().startswith("USERNAME"):
            continue
        m = _QUSER.match(text)
        if not m:
            continue
        user, session, sid, state, idle, logon = m.groups()
        rows.append({
            "user": user,
            "session": session or "",
            "id": int(sid),
            "state": _STATES.get(state.lower(), state.lower()),
            "idle": idle,
            "idle_minutes": idle_minutes(idle),
            "logon": logon,
        })
    return rows


def host_warnings(host: Mapping[str, Any]) -> list[str]:
    warnings: list[str] = []
    if host.get("enabled") and host.get("nla") is False:
        warnings.append("RDP enabled without Network Level Authentication")
    if host.get("enabled") and host.get("firewall_open") is False:
        warnings.append("RDP enabled but the Remote Desktop firewall rules are disabled")
    return warnings


def _clean(value: Any) -> str:
    return re.sub(r"[\r\n]+", "", str(value or "")).strip()


def rdp_file(host: str, username: str = "", gateway: str = "") -> str:
    host, username, gateway = _clean(host), _clean(username), _clean(gateway)
    lines = [
        f"full address:s:{host}",
        "prompt for credentials:i:1",
        "administrative session:i:0",
        "screen mode id:i:2",
        "authentication level:i:2",
        "redirectclipboard:i:1",
    ]
    if username:
        lines.append(f"username:s:{username}")
    if gateway:
        lines += [f"gatewayhostname:s:{gateway}", "gatewayusagemethod:i:1", "gatewayprofileusagemethod:i:1"]
    return "\r\n".join(lines) + "\r\n"


def rdp_uri(host: str, username: str = "") -> str:
    parts = [f"full%20address=s:{quote(_clean(host), safe='.-:')}"]
    if _clean(username):
        parts.append(f"username=s:{quote(_clean(username), safe='')}")
    return "rdp://" + "&".join(parts)


def _hosts_of(args: Mapping[str, Any]) -> list[str]:
    hosts = [h for h in (args.get("hosts") or []) if isinstance(h, str) and h]
    if isinstance(args.get("host"), str) and args["host"]:
        hosts.append(args["host"])
    return hosts


def _touches_dc(args: Mapping[str, Any], settings: Any, facts: Any) -> bool:
    hosts = _hosts_of(args)
    if not hosts:
        return False
    dcs = facts.domain_controllers()
    if dcs is None:
        return True
    return any(is_domain_controller_name(h, dcs) for h in hosts)


def _nla_escalate(args: Mapping[str, Any], settings: Any, facts: Any) -> bool:
    return args.get("required") is False or _touches_dc(args, settings, facts)


def _post_sessions(data: Any, args: Mapping[str, Any], settings: Any) -> Any:
    data = data or {}
    hosts = data.get("hosts") or []
    errors = list(data.get("errors") or [])
    items = [{"host": h.get("host", ""), **s} for h in hosts for s in parse_quser(h.get("lines") or [])]
    wanted = str(args.get("user") or "").strip().lower().split("\\")[-1]
    if wanted:
        items = [i for i in items if wanted in i["user"].lower()]
    return {
        "items": items,
        "errors": errors,
        "summary": {
            "hosts": len(hosts) + len(errors),
            "reachable": len(hosts),
            "sessions": len(items),
            "active": sum(1 for i in items if i["state"] == "active"),
            "disconnected": sum(1 for i in items if i["state"] == "disconnected"),
            "idle_over_60": sum(1 for i in items if (i["idle_minutes"] or 0) > 60),
        },
    }


def _post_host_status(data: Any, args: Mapping[str, Any], settings: Any) -> Any:
    data = data or {}
    items = sorted(
        ({**h, "warnings": host_warnings(h)} for h in data.get("results") or []),
        key=lambda h: str(h.get("host", "")).lower(),
    )
    errors = list(data.get("errors") or [])
    return {
        "items": items,
        "errors": errors,
        "summary": {
            "hosts": len(items) + len(errors),
            "enabled": sum(1 for h in items if h.get("enabled")),
            "nla_off": sum(1 for h in items if h.get("enabled") and h.get("nla") is False),
            "unreachable": len(errors),
        },
    }


def _post_connect(data: Any, args: Mapping[str, Any], settings: Any) -> Any:
    host = str((data or {}).get("host") or args.get("host") or "")
    username = _clean(args.get("username"))
    return {
        "host": host,
        "filename": f"{host.split('.', 1)[0].lower()}.rdp",
        "content": rdp_file(host, username, _clean(args.get("gateway"))),
        "uri": rdp_uri(host, username),
    }


def _session_target(a: Mapping[str, Any]) -> str:
    sid = a.get("session_id")
    return f"{a.get('host', '')} #{sid if sid is not None else 'all'}"


register(Op(
    name="rdp_sessions", toolset=TOOLSET, tier="R", script="rdp_sessions",
    description=(
        "Who is logged on where: RDP/console sessions (active, disconnected, idle time) on the given hosts, "
        "an OU, or every enabled server. Use 'user' to find one person's sessions."
    ),
    params=(HOSTS, OU, Param("user", "string", "Only sessions whose username contains this.")),
    post=_post_sessions, inject=_search_base, cache_ttl=30,
))

register(Op(
    name="rdp_host_status", toolset=TOOLSET, tier="R", script="rdp_host_status",
    description="RDP posture per host: enabled, NLA required, port, firewall rules, Remote Desktop Users members, with warnings.",
    params=(HOSTS, OU),
    post=_post_host_status, inject=_search_base, cache_ttl=60,
))

register(Op(
    name="rdp_connect_file", toolset=TOOLSET, tier="R", script="rdp_connect_file",
    description="Build a .rdp connection file (and rdp:// link) for a computer in AD.",
    params=(
        HOST,
        Param("username", "string", "Pre-filled username, e.g. CORP\\alice."),
        Param("gateway", "string", "RD Gateway host name."),
    ),
    post=_post_connect,
))

register(Op(
    name="rdp_session_logoff", toolset=TOOLSET, tier="W", script="rdp_session_logoff",
    description="Log off a session (unsaved work in it is lost). Get the session ID from rdp_sessions.",
    params=(HOST, SESSION), target=_session_target, preview=True,
))

register(Op(
    name="rdp_session_disconnect", toolset=TOOLSET, tier="W", script="rdp_session_disconnect",
    description="Disconnect a session; the user's programs keep running and they can reconnect.",
    params=(HOST, SESSION), target=_session_target,
))

register(Op(
    name="rdp_session_message", toolset=TOOLSET, tier="W", script="rdp_session_message",
    description="Show a pop-up message in one session, or in every session on the host when session_id is omitted.",
    params=(
        HOST,
        Param("message", "string", "Message text.", required=True),
        Param("session_id", "integer", "Session ID; omit for all sessions.", minimum=0),
        Param("seconds", "integer", "How long the message stays up.", default=60, minimum=5),
    ),
    target=_session_target,
))

register(Op(
    name="rdp_set_enabled", toolset=TOOLSET, tier="W", script="rdp_set_enabled",
    description="Allow or deny Remote Desktop connections on hosts (registry + Remote Desktop firewall rules). High-risk on domain controllers.",
    params=(HOSTS_REQUIRED, Param("enabled", "boolean", "true = allow RDP.", required=True)),
    target=lambda a: ", ".join(a.get("hosts") or []), escalate=_touches_dc, preview=True,
))

register(Op(
    name="rdp_set_nla", toolset=TOOLSET, tier="W", script="rdp_set_nla",
    description="Require (or stop requiring) Network Level Authentication for RDP. Turning NLA off is high-risk.",
    params=(HOSTS_REQUIRED, Param("required", "boolean", "true = require NLA.", required=True)),
    target=lambda a: ", ".join(a.get("hosts") or []), escalate=_nla_escalate,
))

register(Op(
    name="rdp_users_add", toolset=TOOLSET, tier="W", script="rdp_users_add",
    description="Grant RDP access on a host by adding users/groups to its Remote Desktop Users group.",
    params=(HOST, MEMBERS),
    target=lambda a: f"{a.get('host', '')} ← {', '.join(a.get('members') or [])}",
    identities=("members",), escalate=_touches_dc,
))

register(Op(
    name="rdp_users_remove", toolset=TOOLSET, tier="W", script="rdp_users_remove",
    description="Revoke RDP access on a host by removing users/groups from its Remote Desktop Users group.",
    params=(HOST, MEMBERS),
    target=lambda a: f"{a.get('host', '')} → {', '.join(a.get('members') or [])}",
    identities=("members",), escalate=_touches_dc,
))
