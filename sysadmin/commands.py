"""The /ad slash command: deterministic answers with no LLM round-trip. Never raises."""

from __future__ import annotations

from typing import Any, Callable

from . import runtime

USAGE = "\n".join([
    "**/ad**: Active Directory quick commands",
    "- `/ad status`: domain counts and DC health",
    "- `/ad user <name>`: one user",
    "- `/ad unlock <name>`: unlock an account (asks first)",
    "- `/ad sessions [host]`: RDP sessions (all servers when no host is given)",
    "- `/ad backups`: Windows Server Backup status per server",
    "- `/ad catalog <query>`: search the catalog of vetted tasks",
    "- `/ad run <id> key=value … [on HOST,HOST] [ou=DN]`: run a catalog entry (writes ask first)",
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
    r = service.call("ad_user_unlock", args, actor="command", session=session, approved=d.tier)
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


def _catalog(service: Any, rest: list[str], ctx: Any, session: str) -> str:
    r = service.call("catalog_search", {"query": rest[0] if rest else "", "limit": 15}, actor="command", session=session)
    if not r["ok"]:
        return _err(r)
    d = r["data"]
    if not d["items"]:
        return "No catalog entries match."
    lines = [f"- `{i['id']}` · {i['title']} · {i['tier']} · {i['target']}" for i in d["items"]]
    if d["total"] > len(d["items"]):
        lines.append(f"… and {d['total'] - len(d['items'])} more")
    return "\n".join(lines)


def _coerce_token(value: str) -> Any:
    if value.isdigit():
        return int(value)
    if value.lower() in ("true", "false"):
        return value.lower() == "true"
    return value


def _parse_run(text: str) -> tuple[str, dict[str, Any]]:
    """'<id> k=v … [on H1,H2] [ou=DN]' -> (id, args). DN values may contain spaces, so ou= takes the rest."""
    text = text.strip()
    if not text:
        raise ValueError("Usage: /ad run <id> key=value … [on HOST,HOST] [ou=DN]")
    entry_id, _, tail = text.partition(" ")
    args: dict[str, Any] = {}
    params: dict[str, Any] = {}
    tokens = tail.split()
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if tok.lower() == "on" and i + 1 < len(tokens):
            args["computers"] = [h for h in tokens[i + 1].split(",") if h]
            i += 2
        elif tok.lower().startswith("ou="):
            rest = " ".join(tokens[i:])[3:]
            args["ou"] = _unquote(rest)
            break
        elif "=" in tok:
            key, _, value = tok.partition("=")
            params[key] = _coerce_token(_unquote(value))
            i += 1
        else:
            raise ValueError(f"Unexpected '{tok}'. Use key=value, 'on HOST,HOST' or ou=DN.")
    return entry_id, {**params, **args}


def _render_rows(data: Any) -> list[str]:
    if not isinstance(data, dict):
        return [str(data)]
    lines: list[str] = []
    for row in (data.get("items") or [])[:20]:
        if isinstance(row, dict):
            host = row.get("host") or row.get("computer") or row.get("name") or "-"
            rest = " ".join(f"{k}={v}" for k, v in row.items() if k not in ("host", "computer"))
            lines.append(f"{host}: {rest}".rstrip())
        else:
            lines.append(str(row))
    extra = len(data.get("items") or []) - 20
    if extra > 0:
        lines.append(f"… and {extra} more")
    lines += [f"{e.get('host', '-')}: {e.get('message')}" for e in data.get("errors") or [] if isinstance(e, dict)]
    return lines or ["(no rows)"]


def _run(service: Any, rest: list[str], ctx: Any, session: str) -> str:
    try:
        entry_id, merged = _parse_run(rest[0] if rest else "")
    except ValueError as exc:
        return str(exc)
    name = "cat." + entry_id
    r = service.call(name, merged, actor="command", session=session)
    if not r["ok"]:
        return _err(r)
    return "\n".join(_render_rows(r["data"]))


_SUBCOMMANDS: dict[str, Callable[[Any, list[str], Any, str], str]] = {
    "status": _status,
    "user": _user,
    "unlock": _unlock,
    "sessions": _sessions,
    "backups": _backups,
    "catalog": _catalog,
    "run": _run,
}


def _unquote(text: str) -> str:
    text = text.strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "\"'":
        return text[1:-1].strip()
    return text


def make_command(ctx: Any) -> Callable[..., str]:
    def ad(raw_args: str = "", **context: Any) -> str:
        parts = (raw_args or "").strip().split(None, 1)
        if not parts or parts[0].lower() in ("help", "-h", "--help"):
            return USAGE
        sub = parts[0].lower()
        # Every subcommand takes at most one argument: the whole remainder, verbatim, so
        # "CORP\bob" keeps its backslash and "Bob Lee" stays one name.
        rest = [_unquote(parts[1])] if len(parts) > 1 else []
        handler = _SUBCOMMANDS.get(sub)
        if handler is None:
            return f"Unknown subcommand '{sub}'.\n\n{USAGE}"
        try:
            return handler(runtime.get_service(), rest, ctx, str(context.get("session_id") or ""))
        except Exception as exc:
            return f"⚠️ /ad {sub} failed: {exc}"

    return ad
