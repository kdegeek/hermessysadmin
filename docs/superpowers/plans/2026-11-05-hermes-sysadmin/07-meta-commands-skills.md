# Phase 7 — Escape hatch, audit tool, `/ad` command, skills

> Part of the [Hermes Sysadmin plan](README.md). Requires Phases 2–6. All the op modules must exist, because the skill lint checks every tool name a skill mentions.

**Deliverable:**
- `ad_powershell`: an H-tier tool that is off by default and asks for approval on every call with the full script shown.
- `sysadmin_audit_log`.
- A deterministic `/ad` slash command whose `/ad unlock` confirms through `ctx.ask_choice` and goes through the same policy and audit path.
- Seven workflow skills registered with `ctx.register_skill`.

Two small, generic registry extensions make the two Python-only ops possible:
- `Op.local`: the op runs in Python, `local(service, args)`, instead of as a script.
- `Op.enabled`: `enabled(settings) -> bool`. When it returns False, `decide()` blocks the op, so a disabled escape hatch is blocked and audited even when it is called from the dashboard or a command.

---

### Task 1: `Op.local` / `Op.enabled` and the meta ops

**Files:**
- Modify: `sysadmin/registry.py` (two `Op` fields)
- Modify: `sysadmin/policy.py` (`decide()` first check)
- Modify: `sysadmin/service.py` (`_run`)
- Modify: `tests/test_scripts_contract.py` (`REAL_OPS` excludes local ops)
- Create: `sysadmin/ops/meta.py`
- Modify: `sysadmin/ops/__init__.py`, `plugin.yaml`
- Test: `tests/test_ops_meta.py`

**Interfaces:**
- Consumes: `Service.runner.run_text(text, params)`, `Service.audit.query(limit, actor, decision)`, `Service.settings`.
- Produces:
  - `Op.local: Callable[[Service, Mapping], Any] | None = None`
  - `Op.enabled: Callable[[Settings], bool] | None = None`
  - The ops `ad_powershell` (H; params `script` and `reason`, both required) and `sysadmin_audit_log` (R; params `limit` (default 50), `actor` (enum agent|dashboard|command), `decision` (prefix)). `sysadmin_audit_log` returns `{items: [audit rows]}`.

- [ ] **Step 1: Write the failing test** — `tests/test_ops_meta.py`

```python
from dataclasses import replace

from sysadmin import ops  # noqa: F401
from sysadmin.config import Settings
from sysadmin.policy import decide
from sysadmin.registry import OPS

PS = {"script": "Get-Date", "reason": "check clock"}


def test_meta_tiers():
    assert (OPS["ad_powershell"].tier, OPS["ad_powershell"].toolset) == ("H", "ad_meta")
    assert (OPS["sysadmin_audit_log"].tier, OPS["sysadmin_audit_log"].toolset) == ("R", "ad_meta")
    assert OPS["ad_powershell"].local is not None and OPS["sysadmin_audit_log"].local is not None


def test_powershell_is_blocked_by_policy_when_disabled():
    d = decide(OPS["ad_powershell"], PS, Settings())
    assert d.action == "block" and "disabled" in d.reason
    assert decide(OPS["ad_powershell"], PS, Settings(enable_powershell_escape=True)).action == "approve"


def test_disabled_powershell_is_blocked_and_audited(make_service, runner, audit):
    out = make_service().call("ad_powershell", PS, actor="dashboard", approved=True)
    assert out["ok"] is False and out["error"]["type"] == "PolicyBlocked"
    assert runner.calls == []
    assert audit.query(limit=1)[0]["decision"].startswith("blocked:")


def test_enabled_powershell_wraps_script_and_needs_approval(make_service, runner, settings, audit):
    svc = make_service(settings=replace(settings, enable_powershell_escape=True))
    assert svc.call("ad_powershell", PS, actor="agent")["error"]["type"] == "ApprovalRequired"
    runner.responses["<text>"] = {"now": "2026-11-05T12:00:00Z"}
    out = svc.call("ad_powershell", PS, actor="agent", session="s1", approved=True)
    assert out == {"ok": True, "data": {"now": "2026-11-05T12:00:00Z"}}
    assert runner.calls[-1][1]["text"] == "Invoke-Op {\nGet-Date\n}"
    row = audit.query(limit=1)[0]
    assert (row["tool"], row["tier"], row["decision"]) == ("ad_powershell", "H", "approved")


def test_powershell_rejects_oversized_scripts(make_service, settings):
    svc = make_service(settings=replace(settings, enable_powershell_escape=True))
    out = svc.call("ad_powershell", {"script": "x" * 20001, "reason": "r"}, actor="agent", approved=True)
    assert out["error"]["type"] == "InvalidArguments"


def test_audit_log_tool_queries_rows(make_service, audit):
    for actor in ("agent", "dashboard", "agent"):
        audit.record(actor=actor, session="", tool="ad_user_unlock", target="bob", tier="W",
                     decision="approved", result="ok", params={"identity": "bob"})
    svc = make_service()
    out = svc.call("sysadmin_audit_log", {"limit": 2}, actor="agent")
    assert out["ok"] and len(out["data"]["items"]) == 2
    only = svc.call("sysadmin_audit_log", {"actor": "dashboard"}, actor="agent")
    assert [r["actor"] for r in only["data"]["items"]] == ["dashboard"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_ops_meta.py`
Expected: FAIL — `KeyError: 'ad_powershell'`

- [ ] **Step 3: Implement**

`sysadmin/registry.py`: add these two fields at the end of the `Op` dataclass, after `inject`:
```python
    inject: Callable[[Any], Mapping[str, Any]] | None = None  # extra PS params derived from Settings
    local: Callable[[Any, Mapping[str, Any]], Any] | None = None  # run in Python as local(service, args) instead of a script
    enabled: Callable[[Any], bool] | None = None  # enabled(settings) False → decide() blocks the op
```

`sysadmin/policy.py`: make this the first statement of `decide()`:
```python
def decide(op: Any, args: Mapping[str, Any], settings: Any, facts: Facts | None = None) -> Decision:
    if getattr(op, "enabled", None) is not None and not op.enabled(settings):
        return Decision("block", op.tier, f"{op.name} is disabled in the hermes-sysadmin settings.")
    if op.tier == "R":
        return Decision("allow", "R", "Read-only operation.")
    # ... rest unchanged
```

`sysadmin/service.py`: replace `_run`:
```python
    def _run(self, op: Op, clean: dict[str, Any]) -> Any:
        if op.local is not None:
            data = op.local(self, clean)
        else:
            data = self.runner.run(op.script, self._params(op, clean), retry=op.tier == "R")
        return op.post(data, clean, self.settings) if op.post else data
```

`tests/test_scripts_contract.py`: change the `REAL_OPS` line:
```python
REAL_OPS = [op for op in OPS.values() if not op.name.startswith("t_") and op.local is None]
```

`sysadmin/ops/meta.py`:
```python
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
    name="ad_powershell", toolset=TOOLSET, tier="H", script="",
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
```

`sysadmin/ops/__init__.py`:
```python
"""Importing this package registers every operation in sysadmin.registry.OPS."""

from . import backup, domain, gpo, meta, rdp, users  # noqa: F401
```

`plugin.yaml` `provides_tools`: append these, keeping the list sorted:
```yaml
  - ad_powershell
  - sysadmin_audit_log
```

- [ ] **Step 4: Run tests**

Run: `.venv/bin/pytest`
Expected: all pass (`tests/test_ops_meta.py`: 6 passed; the contract test skips the two local ops; `test_manifest_declares_exactly_what_register_registers` still passes because `register_tools` registers `ad_powershell` with `check_fn`, so Hermes hides it when the setting is off).

- [ ] **Step 5: Commit**

```bash
git add sysadmin tests plugin.yaml
git commit -m "feat: ad_powershell escape hatch and audit-log tool

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `/ad` slash command

**Files:**
- Create: `sysadmin/commands.py`
- Test: `tests/test_commands.py`

**Interfaces:**
- Consumes:
  - `runtime.get_service()`.
  - `Service.call/decision/record_denied`.
  - `ctx.ask_choice(question, choices) -> value | None`. It works only inside slash-command handlers; choices are `{value, label}` dicts.
  - The Hermes command handler contract: `fn(raw_args: str, **context) -> str`. Hermes passes `session_id` (and other context) when the handler accepts `**kwargs`.
- Produces: `make_command(ctx) -> Callable[..., str]`, `USAGE`. Subcommands: `status`, `user <name>`, `unlock <name>`, `sessions [host]`, `backups`, `help`.

- [ ] **Step 1: Write the failing test** — `tests/test_commands.py`

```python
from dataclasses import replace

import pytest

from sysadmin import commands, ops, runtime  # noqa: F401

DC = {
    "name": "DC01", "site": "HQ", "reachable": True,
    "services": {"NTDS": "Running", "Netlogon": "Running", "KDC": "Running", "DNS": "Running", "W32Time": "Running"},
    "sysvol_shared": True, "netlogon_shared": True, "time_skew_seconds": 0.2, "replication": {"failures": 0},
}


class Ctx:
    def __init__(self, answer="unlock"):
        self.answer, self.asked = answer, []

    def ask_choice(self, question, choices):
        self.asked.append((question, choices))
        return self.answer


@pytest.fixture
def run(monkeypatch, make_service):
    def go(text, ctx=None, svc=None):
        service = svc or make_service()
        monkeypatch.setattr(runtime, "get_service", lambda: service)
        return commands.make_command(ctx or Ctx())(text, session_id="cli-1")

    return go


def test_help_and_unknown(run):
    assert "/ad status" in run("")
    assert run("frobnicate").startswith("Unknown subcommand 'frobnicate'")


def test_status(run, runner):
    runner.responses["ad_domain_overview"] = {
        "domain": "corp.example.local", "netbios": "CORP", "forest": "corp.example.local", "expiring_days": 7,
        "counts": {"users": 1240, "users_disabled": 88, "users_locked": 3, "passwords_expiring": 17,
                   "computers": 410, "computers_stale": 22, "gpos": 41},
    }
    runner.responses["ad_dc_health"] = {"items": [DC], "errors": []}
    out = run("status")
    assert "**corp.example.local** (CORP)" in out
    assert "Users 1240 · disabled 88 · locked 3" in out
    assert "🟢 DC01 (HQ)" in out


def test_user(run, runner):
    runner.responses["ad_user_get"] = {
        "sam": "bob", "name": "Bob Lee", "ou": "OU=Staff,DC=corp", "enabled": True, "locked": True,
        "last_logon": "2026-11-04T08:00:00Z", "password_expires": None, "groups": ["Finance", "VPN Users"],
    }
    out = run("user bob")
    assert "**Bob Lee** (bob)" in out and "🔒 locked" in out and "Finance, VPN Users" in out
    assert run("user") == "Usage: /ad user <name>"


def test_unlock_confirmed_runs_and_audits_as_command(run, runner, audit):
    ctx = Ctx("unlock")
    out = run("unlock bob", ctx)
    assert out == "✅ Unlocked bob."
    assert ctx.asked and "Unlock bob?" in ctx.asked[0][0]
    assert runner.calls[-1][0] == "ad_user_unlock"
    row = audit.query(limit=1)[0]
    assert (row["actor"], row["decision"], row["session"]) == ("command", "approved", "cli-1")


def test_unlock_cancelled_records_denial(run, runner, audit):
    out = run("unlock bob", Ctx(None))
    assert out == "Cancelled — bob was not unlocked."
    assert all(c[0] != "ad_user_unlock" for c in runner.calls)
    assert audit.query(limit=1)[0]["decision"].startswith("denied:")


def test_unlock_protected_is_blocked_without_prompt(run):
    ctx = Ctx()
    out = run("unlock krbtgt", ctx)
    assert out.startswith("⛔") and "protected" in out
    assert ctx.asked == []


def test_unlock_permissive_skips_prompt(run, make_service, settings, runner):
    ctx = Ctx()
    svc = make_service(settings=replace(settings, mode="permissive"))
    assert run("unlock bob", ctx, svc) == "✅ Unlocked bob."
    assert ctx.asked == []


def test_sessions(run, runner):
    runner.responses["rdp_sessions"] = {
        "hosts": [{"host": "SRV1", "lines": [" alice  rdp-tcp#2  2  Active  .  11/4/2026 8:01 AM"]}], "errors": [],
    }
    out = run("sessions SRV1")
    assert runner.calls[-1][1]["Hosts"] == ["SRV1"]
    assert "1 session(s) on 1 host(s)" in out and "SRV1 · alice · #2 · active" in out


def test_backups(run, runner):
    runner.responses["backup_status"] = {
        "results": [{"host": "SRV-RDS01", "installed": False, "policy": False, "versions": 0, "job": None}],
        "errors": [{"host": "SRV9", "message": "unreachable"}],
    }
    out = run("backups")
    assert "⚪ SRV-RDS01 — none · Windows Server Backup feature not installed" in out
    assert "🔴 SRV9 — unreachable" in out


def test_command_never_raises(monkeypatch):
    def boom():
        raise RuntimeError("no runtime")

    monkeypatch.setattr(runtime, "get_service", boom)
    assert commands.make_command(Ctx())("status").startswith("⚠️ /ad status failed")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_commands.py`
Expected: FAIL — `ImportError: cannot import name 'commands'`

- [ ] **Step 3: Implement** — `sysadmin/commands.py`

```python
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.venv/bin/pytest tests/test_commands.py`
Expected: `10 passed`

- [ ] **Step 5: Commit**

```bash
git add sysadmin/commands.py tests/test_commands.py
git commit -m "feat: /ad slash command

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Skills and `register()` wiring

**Files:**
- Create (7): `skills/onboard-user/SKILL.md`, `skills/offboard-user/SKILL.md`, `skills/lockout-triage/SKILL.md`, `skills/gpo-change/SKILL.md`, `skills/domain-health-check/SKILL.md`, `skills/access-review/SKILL.md`, `skills/backup-recovery-guide/SKILL.md`
- Modify: `__init__.py`
- Modify: `tests/test_plugin.py` (append tests)

**Interfaces:**
- Consumes: `ctx.register_skill(name, path)` (path = the SKILL.md file; must exist), `ctx.register_command(name, handler, description, args_hint)`, `commands.make_command`.
- Produces: `SKILLS` tuple in the root `__init__.py`. Skills resolve as `hermes-sysadmin:<name>`.

- [ ] **Step 1: Write the failing tests**: append to `tests/test_plugin.py`

```python
import re

from sysadmin.tools import EMOJI

SKILL_NAMES = {
    "onboard-user", "offboard-user", "lockout-triage", "gpo-change",
    "domain-health-check", "access-review", "backup-recovery-guide",
}
TOOL_WORD = re.compile(r"\b(?:ad|gpo|rdp|backup|sysadmin)_[a-z_]+\b")


def _frontmatter(text):
    assert text.startswith("---\n"), "SKILL.md must start with YAML frontmatter"
    head, body = text[4:].split("\n---\n", 1)
    return yaml.safe_load(head), body


def test_register_adds_skills_and_ad_command():
    ctx = FakeCtx()
    load_plugin().register(ctx)
    assert set(ctx.skills) == SKILL_NAMES
    assert all(p.is_file() and p.name == "SKILL.md" for p in ctx.skills.values())
    handler, description, args_hint = ctx.commands["ad"]
    assert callable(handler) and "status" in args_hint


def test_skills_are_well_formed_and_only_name_real_tools():
    known = set(OPS) | set(EMOJI)
    for name in SKILL_NAMES:
        meta, body = _frontmatter((ROOT / "skills" / name / "SKILL.md").read_text(encoding="utf-8"))
        assert meta["name"] == name
        assert 20 <= len(meta["description"]) <= 1024
        unknown = sorted(set(TOOL_WORD.findall(body)) - known)
        assert not unknown, f"{name} mentions unknown tools: {unknown}"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv/bin/pytest tests/test_plugin.py`
Expected: FAIL — `AssertionError` in `test_register_adds_skills_and_ad_command` (`set() != {...}`)

- [ ] **Step 3: Write the skills**

`skills/onboard-user/SKILL.md`:
```markdown
---
name: onboard-user
description: Create a new Active Directory user from a template or role (OU, groups), set an initial password, optionally grant RDP access, and hand back a summary. Use when asked to onboard, add, or set up a new employee or account.
---

# Onboard a user

1. **Gather inputs.** You need first and last name and a logon name (sAMAccountName). Ask for a template user ("same as Jane") or an OU, plus title and department. Do not invent a logon name: propose one that follows the domain's pattern (`ad_user_list` with `query` set to a colleague) and confirm it.
2. **Check for collisions.** Call `ad_search` with the proposed logon name. If it exists, stop and ask.
3. **Inspect the template.** Call `ad_user_get` on the template to show its OU and groups. Privileged groups are never copied. Say so if the template has any.
4. **Create.** Call `ad_user_create` with `template` (or `ou`), the names, title, department and `must_change: true`. Omit `password` so one is generated. The user approves the call.
5. **Extra groups.** For each extra group the user asked for, call `ad_group_add_member`. A privileged group becomes a high-risk approval; explain why before you call it.
6. **RDP (optional).** If they need remote desktop access to specific servers, call `rdp_users_add` with each host.
7. **Summarise.** Give the logon name, UPN, OU, groups and RDP hosts. Show the generated password **once**, and tell the user to pass it on through a secure channel. Never repeat the password later in the conversation.
```

`skills/offboard-user/SKILL.md`:
```markdown
---
name: offboard-user
description: Safely offboard a departing user in Active Directory: disable, reset to a random password, remove group memberships (recorded for restore), move to a Disabled OU, log off RDP sessions and stamp the description. Use when someone leaves or an account must be shut off.
---

# Offboard a user

Ask for the user, the ticket or reference, and the Disabled OU's DN (look it up with `ad_search` and `kind: "ou"` if needed). Then confirm the plan in one message before you start.

1. **Snapshot.** Call `ad_user_get`. Keep the full group list in your reply; it is the restore record, and every removal is also in the audit log (`sysadmin_audit_log`).
2. **Disable.** Call `ad_user_disable` with `note` set to `Offboarded <YYYY-MM-DD> <ticket>`.
3. **Random password.** Call `ad_user_reset_password` with no `password` and `must_change: false`. Do not show the generated password. Say only that it was rotated.
4. **Sessions.** Call `rdp_sessions` with `user`. For each session found, call `rdp_session_logoff` with that host and `session_id`.
5. **Groups.** For each group except Domain Users, call `ad_group_remove_member`. Privileged groups are high-risk and need their own approval.
6. **Move.** Call `ad_user_move` with `target_ou` set to the Disabled OU.
7. **Report.** List what changed and the groups removed (the restore list). Recommend deleting the account only after the retention period. `ad_user_delete` is high-risk; do not call it unless explicitly asked.
```

`skills/lockout-triage/SKILL.md`:
```markdown
---
name: lockout-triage
description: Find out why an Active Directory account keeps locking out, identify the source computer, explain the likely cause (stale credentials in a service, mapped drive, phone, RDP session), unlock it and give a fix. Use for "X is locked out" or repeated lockouts.
---

# Lockout triage

1. **State.** Call `ad_user_get`. Note whether the account is locked, its bad-password count and lockout time.
2. **Source.** Call `ad_lockout_source` (`hours: 24`; widen to 72 for recurring cases). Report `likely_source` and the 4740 events per DC.
3. **Inspect the source.**
   - If the source is a server, call `rdp_sessions` with `hosts` set to that server and `user` set to the account. A disconnected session that was left running with an old password is the classic cause.
   - If the source is a workstation or a phone or Wi-Fi name (often a blank or odd caller name), say that it is probably cached credentials on a device.
4. **Unlock.** Call `ad_user_unlock`. If the user also forgot the password, call `ad_user_reset_password` instead; it unlocks too.
5. **Fix the cause.** Give the specific next step:
   - Log off the stale session with `rdp_session_logoff`.
   - Update the saved credentials on the device.
   - Update a service or scheduled task's stored password.
   - Remove a mapped drive that uses old credentials.

   If lockouts continue after the fix, say that `ad_lockout_source` should be re-run.
```

`skills/gpo-change/SKILL.md`:
```markdown
---
name: gpo-change
description: Make a Group Policy change safely: back up, apply (link/unlink/enforce/status/security filter), refresh a test host, verify with RSoP, and roll back on failure. Use for any request that changes where or how a GPO applies.
---

# Change Group Policy safely

1. **Understand the GPO.** Call `gpo_get` for its links and security filtering, and `gpo_report` (`format: "summary"`) for what it configures. Restate the intended effect in one sentence and confirm it.
2. **Back up.** Call `gpo_backup` with a comment that describes the change. Keep the returned backup ID.
3. **Apply.** Use the narrowest tool:
   - `gpo_link` or `gpo_unlink` to change where the GPO applies. Linking at the domain root, the Domain Controllers OU or a site is high-risk.
   - `gpo_set_link` to enforce, unenforce, enable or disable a link.
   - `gpo_set_status` to switch user or computer settings on or off.
   - `gpo_set_security_filter` to change who the GPO applies to.

   Create new GPOs with `gpo_create`. Editing settings is out of scope; tell the user to use GPMC for that.
4. **Refresh a test host.** Ask for one computer in scope, then call `gpo_update_hosts` with `computers: [that host]`.
5. **Verify.** Call `gpo_rsop` on that computer and check that the GPO is listed as applied (or no longer applied). If the result is wrong, explain why from the RSoP output: filtered, access denied, or not linked.
6. **Roll back on failure.** If verification fails and the user agrees, undo the link change with the opposite tool. For settings changes, call `gpo_restore` with the backup ID from step 2.
7. **Roll out.** When the result is right, offer `gpo_update_hosts` for the whole OU (`ou`). Finish with what changed and the backup ID.
```

`skills/domain-health-check/SKILL.md`:
```markdown
---
name: domain-health-check
description: Run a full Active Directory health check (domain controllers, replication, FSMO, time, SYSVOL, backup staleness, GPO health, privileged membership, account hygiene) and produce a prioritised report. Use for "is AD healthy", weekly checks, or before maintenance.
---

# Domain health check

Run these reads; all of them are read-only and need no approval:

1. `ad_domain_overview`: counts, FSMO holders, functional levels, Recycle Bin status.
2. `ad_dc_health`: per-DC services, SYSVOL/NETLOGON shares, time skew and replication failures.
3. `backup_status`: system-state backup age per server against the configured stale threshold. Pay most attention to DCs.
4. `gpo_health`: unlinked, empty, disabled or version-mismatched GPOs.
5. `ad_user_list` with `privileged: true`: who holds admin rights.
6. `ad_user_list` with `password: "never_expires"`, then with `stale_days: 90`: hygiene.

Write the report as:
- **Critical:** a DC down or failing replication, a DC without a recent system-state backup, time skew over 5 minutes.
- **Warnings:** stale backups on other servers, GPO version mismatches, a growing privileged group, many stale or never-expiring accounts.
- **Info:** counts and FSMO placement.

Give each item the evidence (the numbers) and one concrete next action. Offer the matching skill (for example `gpo-change` or `backup-recovery-guide`) where it helps. Do not change anything during a health check.
```

`skills/access-review/SKILL.md`:
```markdown
---
name: access-review
description: Review who has privileged and remote access in Active Directory: privileged group members, Remote Desktop Users per server, RDP posture, and accounts with non-expiring passwords; produce a review table with recommended removals. Use for audits, quarterly access reviews or "who are our admins".
---

# Access review

1. **Privileged groups.** For each of Domain Admins, Enterprise Admins, Schema Admins, Administrators, Account Operators, Server Operators, Backup Operators and Group Policy Creator Owners, call `ad_group_get`. Flag nested groups, disabled members and members whose last logon is more than 90 days ago (use `ad_user_get` for details).
2. **Remote Desktop.** Call `rdp_host_status` for all servers. List the Remote Desktop Users members for each host and every warning (NLA off, firewall rules disabled).
3. **Password policy exceptions.** Call `ad_user_list` with `password: "never_expires"`. Separate service accounts from people.
4. **Report.** Build one table: principal · access · where · last logon · recommendation (keep / remove / investigate).
5. **Remediate only on request.**
   - Removals use `ad_group_remove_member` (privileged groups are high-risk) or `rdp_users_remove`.
   - Turning NLA on uses `rdp_set_nla` with `required: true`.

   Every change needs approval and is logged; `sysadmin_audit_log` shows them afterwards.
```

`skills/backup-recovery-guide/SKILL.md`:
```markdown
---
name: backup-recovery-guide
description: Runbook for Active Directory recovery with Windows Server Backup. It covers checking backups, taking a fresh system-state backup, and guiding non-authoritative and authoritative restores (DSRM, wbadmin, ntdsutil), plus single-object recovery via the AD Recycle Bin. Use when a DC fails, objects are deleted, or someone asks how to restore AD.
---

# AD backup and recovery

The plugin does not perform restores. Restores need console or DSRM access to the DC. Use the tools to assess the situation and prepare, then walk the user through the steps.

## 1. Assess
- Call `backup_status` and `backup_versions` for the affected DC. Confirm that a system-state version exists and is newer than the tombstone lifetime (180 days by default).
- For deleted objects, call `ad_recycle_bin_list` first. If the object is there, call `ad_recycle_bin_restore`. This is the simplest recovery and needs no DC restore.

## 2. Protect what is left
- If any healthy DC has a stale backup, offer `backup_start` with `kind: "system_state"` and watch progress with `backup_jobs`.

## 3. Choose the restore type
- **Non-authoritative** (one DC is corrupt or failed; other DCs are healthy): the restored DC catches up through replication. Often it is simpler to demote and rebuild the DC.
- **Authoritative** (deleted objects must win over replication and the Recycle Bin was not enabled): restore non-authoritatively first, then mark the objects authoritative.

## 4. Steps to give the user (run at the DC console)
1. Boot into Directory Services Restore Mode: `bcdedit /set safeboot dsrepair`, then restart.
2. `wbadmin get versions`, then `wbadmin start systemstaterecovery -version:<id>`.
3. For authoritative restores only, before rebooting:
   - `ntdsutil "activate instance ntds" "authoritative restore" "restore subtree <DN>" q q`
   - Then import the generated LDIF files for back-links.
4. `bcdedit /deletevalue safeboot`, then restart.
5. Verify the result with `ad_dc_health` and `ad_search` for the restored objects.

Never suggest restoring a DC from a VM snapshot (it causes USN rollback). Never run these steps through `ad_powershell`.
```

- [ ] **Step 4: Wire `register()`.** Replace the root `__init__.py`:

```python
"""hermes-sysadmin — Active Directory, Group Policy, RDP and Windows Server Backup over WinRM.

Install:  hermes plugins install <owner>/hermessysadmin --enable
Dev loop: ln -s "$PWD" ~/.hermes/plugins/hermes-sysadmin && hermes plugins enable hermes-sysadmin
"""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parent
SKILLS = (
    "onboard-user",
    "offboard-user",
    "lockout-triage",
    "gpo-change",
    "domain-health-check",
    "access-review",
    "backup-recovery-guide",
)


def register(ctx):
    from .sysadmin import commands, hooks, tools

    tools.register_tools(ctx)
    ctx.register_hook("pre_tool_call", hooks.pre_tool_call)
    ctx.register_hook("post_tool_call", hooks.post_tool_call)
    for name in SKILLS:
        ctx.register_skill(name, ROOT / "skills" / name / "SKILL.md")
    ctx.register_command(
        "ad",
        commands.make_command(ctx),
        description="Active Directory quick commands (no LLM round-trip)",
        args_hint="status | user <name> | unlock <name> | sessions [host] | backups",
    )
```

- [ ] **Step 5: Run tests and validate**

Run:
```bash
.venv/bin/pytest
hermes plugins validate "$(git rev-parse --show-toplevel)" --install-deps
hermes plugins doctor "$(git rev-parse --show-toplevel)" --ci
```
Expected: all tests pass, and both Hermes commands exit 0. If Hermes reports that `/ad` conflicts with a built-in command, rename it to `/adm` in `register()`, `USAGE` and the tests, then rerun.

- [ ] **Step 6: Try it in Hermes** (dev symlink from Phase 2)

```bash
hermes plugins enable hermes-sysadmin
hermes chat -q "/ad status"
hermes chat -q "/ad backups"
```
Expected: formatted status and backup lines. Then, in an interactive `hermes chat`:
- Run `/ad unlock zz-hermes-test-1`. A picker should appear.
- Ask "use the lockout-triage skill for zz-hermes-test-1". The agent should load `hermes-sysadmin:lockout-triage`.

- [ ] **Step 7: Commit**

```bash
git add skills __init__.py tests/test_plugin.py
git commit -m "feat: workflow skills and /ad command registration

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
