"""The /ad slash command: deterministic answers with no LLM round-trip. Never raises."""

from __future__ import annotations

import shlex
from typing import Any, Callable

from . import runtime

USAGE = "\n".join([
    "**/ad**: Active Directory quick commands",
    "- `/ad status`: domain counts and DC health",
    "- `/ad user <name>`: one user",
    "- `/ad unlock <name>`: unlock an account (asks first)",
    "- `/ad sessions [host]`: RDP sessions (all servers when no host is given)",
    "- `/ad backups`: Windows Server Backup status per server",
])
HEALTH = {"ok": "🟢", "warn": "🟡", "bad": "🔴"}
BACKUP = {"ok": "🟢", "bad": "🔴", "run": "🔵", "none": "⚪"}


def _err(result: dict[str, Any]) -> str:
    e = result.get("error") or {}
    icon = "⛔" if e.get("type") == "PolicyBlocked" else "⚠️"
    hint = f"\n{e['hint']}" if e.get("hint") else ""
    return f"{icon} {e.get('type', 'Error')}: {e.get('message', '')}{hint}"


def _status(service: Any, rest: list[str], ctx: Any, session: str) -> str:
    ov = service.call("ad_domain_overview", {}, actor="command", session=session)
    if not ov["ok"]:
        return _err(ov)
    d = ov["data"]
    c = d.get("counts") or {}
    lines = [
        f"**{d.get('domain')}** ({d.get('netbios')}) · forest {d.get('forest')}",
        f"Users {c.get('users')} · disabled {c.get('users_disabled')} · locked {c.get('users_locked')} · "
        f"expiring ≤{d.get('expiring_days')}d {c.get('passwords_expiring')}",
        f"Computers {c.get('computers')} (stale {c.get('computers_stale')}) · GPOs {c.get('gpos')}",
    ]
    health = service.call("ad_dc_health", {}, actor="command", session=session)
    if not health["ok"]:
        return "\n".join(lines + [_err(health)])
    h = health["data"]
    lines.append(f"DC health: {HEALTH.get(h.get('status'), '•')} {h.get('status')}")
    lines += [f"- {HEALTH.get(dc.get('status'), '•')} {dc.get('name')} ({dc.get('site')})" for dc in h.get("items") or []]
    lines += [f"- 🔴 {e.get('host')}: {e.get('message')}" for e in h.get("errors") or []]
    return "\n".join(lines)


def _user(service: Any, rest: list[str], ctx: Any, session: str) -> str:
    if not rest:
        return "Usage: /ad user <name>"
    r = service.call("ad_user_get", {"identity": rest[0]}, actor="command", session=session)
    if not r["ok"]:
        return _err(r)
    u = r["data"]
    flags = ["enabled" if u.get("enabled") else "disabled"]
    if u.get("locked"):
        flags.append("🔒 locked")
    if u.get("privileged"):
        flags.append("⚠️ privileged")
    groups = u.get("groups") or []
    return "\n".join([
        f"**{u.get('name')}** ({u.get('sam')}) · {' · '.join(flags)}",
        f"OU: {u.get('ou')}",
        f"Last logon: {u.get('last_logon') or 'never'} · password expires: {u.get('password_expires') or 'n/a'}",
        f"Groups: {', '.join(groups[:12]) or 'none'}{' …' if len(groups) > 12 else ''}",
    ])


def _unlock(service: Any, rest: list[str], ctx: Any, session: str) -> str:
    if not rest:
        return "Usage: /ad unlock <name>"
    name = rest[0]
    args = {"identity": name}
    d = service.decision("ad_user_unlock", args)
    if d.action == "block":
        # Service.call records the block in the audit log exactly once.
        return _err(service.call("ad_user_unlock", args, actor="command", session=session))
    if d.action == "approve":
        choice = ctx.ask_choice(
            f"Unlock {name}? ({d.reason})",
            [{"value": "unlock", "label": "Unlock"}, {"value": "cancel", "label": "Cancel"}],
        )
        if choice != "unlock":
            service.record_denied("ad_user_unlock", args, actor="command", session=session, reason="cancelled in /ad")
            return f"Cancelled — {name} was not unlocked."
    r = service.call("ad_user_unlock", args, actor="command", session=session, approved=True)
    return f"✅ Unlocked {name}." if r["ok"] else _err(r)


def _sessions(service: Any, rest: list[str], ctx: Any, session: str) -> str:
    args = {"hosts": [rest[0]]} if rest else {}
    r = service.call("rdp_sessions", args, actor="command", session=session)
    if not r["ok"]:
        return _err(r)
    data = r["data"]
    s = data["summary"]
    lines = [f"{s['sessions']} session(s) on {s['reachable']} host(s) · active {s['active']} · disconnected {s['disconnected']}"]
    for i in data["items"][:30]:
        lines.append(f"- {i['host']} · {i['user']} · #{i['id']} · {i['state']} · idle {i['idle']}")
    if len(data["items"]) > 30:
        lines.append(f"… and {len(data['items']) - 30} more")
    lines += [f"- 🔴 {e.get('host')}: {e.get('message')}" for e in data.get("errors") or []]
    return "\n".join(lines)


def _backups(service: Any, rest: list[str], ctx: Any, session: str) -> str:
    r = service.call("backup_status", {}, actor="command", session=session)
    if not r["ok"]:
        return _err(r)
    lines = []
    for h in r["data"]["items"]:
        age = f" · system state {round(h['age_hours'] / 24, 1)} d old" if h.get("age_hours") is not None else ""
        msg = f" · {h['message']}" if h.get("message") else ""
        lines.append(f"{BACKUP.get(h['state'], '•')} {h['host']} — {h['state']}{age}{msg}")
    lines += [f"🔴 {e.get('host')} — unreachable: {e.get('message')}" for e in r["data"].get("errors") or []]
    return "\n".join(lines) or "No servers found."


_SUBCOMMANDS: dict[str, Callable[[Any, list[str], Any, str], str]] = {
    "status": _status,
    "user": _user,
    "unlock": _unlock,
    "sessions": _sessions,
    "backups": _backups,
}


def make_command(ctx: Any) -> Callable[..., str]:
    def ad(raw_args: str = "", **context: Any) -> str:
        try:
            parts = shlex.split(raw_args or "")
        except ValueError:
            parts = (raw_args or "").split()
        if not parts or parts[0].lower() in ("help", "-h", "--help"):
            return USAGE
        sub, rest = parts[0].lower(), parts[1:]
        handler = _SUBCOMMANDS.get(sub)
        if handler is None:
            return f"Unknown subcommand '{sub}'.\n\n{USAGE}"
        try:
            return handler(runtime.get_service(), rest, ctx, str(context.get("session_id") or ""))
        except Exception as exc:
            return f"⚠️ /ad {sub} failed: {exc}"

    return ad
