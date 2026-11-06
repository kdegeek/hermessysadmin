# Phase 5 — Remote Access / RDP

> Part of the [Hermes Sysadmin plan](README.md). Requires Phase 2. Follows the surface pattern described at the top of Phase 2.

**Deliverable:** 10 RDP tools (toolset `ad_rdp`): session inventory across servers (`quser`, parsed in Python), per-host RDP posture (enabled / NLA / firewall / Remote Desktop Users), session control, host access changes with DC escalation, and `.rdp` connection files used by the dashboard's **Connect** button. It also adds two prelude helpers that Phase 6 reuses.

| Op | Tier | Notes |
|---|---|---|
| `rdp_sessions` | R | hosts / OU / all servers (`server_search_base`); optional `user` filter; post parses `quser` |
| `rdp_host_status` | R | enabled, NLA, port, firewall, RDP users; post adds `warnings` |
| `rdp_connect_file` | R | resolves the host in AD; post builds `.rdp` content + `rdp://` URI |
| `rdp_session_logoff` | W | preview (shows the host's current sessions) |
| `rdp_session_disconnect`, `rdp_session_message` | W | |
| `rdp_set_enabled` | W→H | escalates when any host is a DC, or when the DC list is unknown; preview |
| `rdp_set_nla` | W→H | escalates when disabling NLA or touching a DC |
| `rdp_users_add`, `rdp_users_remove` | W→H | escalate on DCs (the DC group is the domain's BUILTIN group) |

PowerShell's `$Host` is a read-only automatic variable, so every `host` param maps to `-ComputerName` (`Param(..., ps="ComputerName")`).

---

### Task 1: RDP ops (Python)

**Files:**
- Create: `sysadmin/ops/rdp.py`
- Modify: `sysadmin/ops/__init__.py`
- Test: `tests/test_ops_rdp.py`

**Interfaces:**
- Consumes: `Op`, `Param`, `register`, `is_domain_controller_name`, `Facts.domain_controllers()`.
- Produces: helpers `parse_quser(lines: list[str]) -> list[dict]`, `idle_minutes(text: str) -> int | None`, `host_warnings(host: Mapping) -> list[str]`, `rdp_file(host, username="", gateway="") -> str`, `rdp_uri(host, username="") -> str`. Session row: `{host, user, session, id, state: "active"|"disconnected"|..., idle, idle_minutes, logon}`. Host row: `{host, enabled, nla, port, firewall_open, rdp_users: list|None, os, last_boot, warnings}`. Connect file: `{host, filename, content, uri}`.

- [ ] **Step 1: Write the failing test** — `tests/test_ops_rdp.py`

```python
import pytest

from sysadmin import ops  # noqa: F401
from sysadmin.config import Settings
from sysadmin.ops.rdp import host_warnings, idle_minutes, parse_quser, rdp_file, rdp_uri
from sysadmin.policy import decide
from sysadmin.registry import OPS, ps_params

EXPECTED = {
    "rdp_sessions": ("R", False), "rdp_host_status": ("R", False), "rdp_connect_file": ("R", False),
    "rdp_session_logoff": ("W", True), "rdp_session_disconnect": ("W", False), "rdp_session_message": ("W", False),
    "rdp_set_enabled": ("W", True), "rdp_set_nla": ("W", False),
    "rdp_users_add": ("W", False), "rdp_users_remove": ("W", False),
}

QUSER = [
    " USERNAME              SESSIONNAME        ID  STATE   IDLE TIME  LOGON TIME",
    " alice                 rdp-tcp#12          2  Active          .  11/4/2026 8:01 AM",
    " bob                                       3  Disc         1:02  11/3/2026 4:15 PM",
    ">carol                 console             1  Active       none  11/1/2026 9:00 AM",
    " dave                  rdp-tcp#14          4  Active    2+03:04  10/31/2026 7:30 AM",
]


class DCs:
    def __init__(self, names):
        self.names = names

    def domain_controllers(self):
        return self.names


DC = DCs(["DC01.corp.local"])


@pytest.mark.parametrize("name", sorted(EXPECTED))
def test_tiers(name):
    assert (OPS[name].tier, OPS[name].preview) == EXPECTED[name]
    assert OPS[name].toolset == "ad_rdp"


def test_parse_quser():
    rows = parse_quser(QUSER)
    assert [(r["user"], r["session"], r["id"], r["state"], r["idle_minutes"]) for r in rows] == [
        ("alice", "rdp-tcp#12", 2, "active", 0),
        ("bob", "", 3, "disconnected", 62),
        ("carol", "console", 1, "active", 0),
        ("dave", "rdp-tcp#14", 4, "active", 3064),
    ]
    assert rows[1]["logon"] == "11/3/2026 4:15 PM"


def test_parse_quser_ignores_no_user_message():
    assert parse_quser(["No User exists for *"]) == []


@pytest.mark.parametrize(
    "text, minutes",
    [(".", 0), ("none", 0), ("45", 45), ("1:02", 62), ("2+03:04", 3064), ("garbage", None)],
)
def test_idle_minutes(text, minutes):
    assert idle_minutes(text) == minutes


def test_sessions_post_flattens_and_summarises():
    data = {
        "hosts": [{"host": "SRV1", "lines": QUSER}, {"host": "SRV2", "lines": ["No User exists for *"]}],
        "errors": [{"host": "SRV3", "message": "WinRM cannot complete the operation"}],
    }
    out = OPS["rdp_sessions"].post(data, {}, Settings())
    assert len(out["items"]) == 4 and out["items"][0]["host"] == "SRV1"
    assert out["summary"] == {"hosts": 3, "reachable": 2, "sessions": 4, "active": 3, "disconnected": 1, "idle_over_60": 2}
    assert out["errors"][0]["host"] == "SRV3"


def test_sessions_post_filters_by_user_ignoring_domain_prefix():
    data = {"hosts": [{"host": "SRV1", "lines": QUSER}], "errors": []}
    out = OPS["rdp_sessions"].post(data, {"user": "CORP\\BOB"}, Settings())
    assert [i["user"] for i in out["items"]] == ["bob"]
    assert out["summary"]["sessions"] == 1


@pytest.mark.parametrize(
    "host, warnings",
    [
        ({"enabled": True, "nla": False, "firewall_open": True}, ["RDP enabled without Network Level Authentication"]),
        ({"enabled": True, "nla": True, "firewall_open": False}, ["RDP enabled but the Remote Desktop firewall rules are disabled"]),
        ({"enabled": False, "nla": False, "firewall_open": False}, []),
    ],
)
def test_host_warnings(host, warnings):
    assert host_warnings(host) == warnings


def test_host_status_post():
    data = {
        "results": [
            {"host": "B", "enabled": False, "nla": True, "firewall_open": False},
            {"host": "A", "enabled": True, "nla": False, "firewall_open": True},
        ],
        "errors": [{"host": "C", "message": "unreachable"}],
    }
    out = OPS["rdp_host_status"].post(data, {}, Settings())
    assert [h["host"] for h in out["items"]] == ["A", "B"]
    assert out["items"][0]["warnings"] == ["RDP enabled without Network Level Authentication"]
    assert out["summary"] == {"hosts": 3, "enabled": 1, "nla_off": 1, "unreachable": 1}


def test_set_enabled_escalates_on_dcs_and_when_dcs_unknown():
    s = Settings()
    op = OPS["rdp_set_enabled"]
    assert decide(op, {"hosts": ["dc01"], "enabled": True}, s, DC).tier == "H"
    assert decide(op, {"hosts": ["srv1.corp.local"], "enabled": True}, s, DC).tier == "W"
    assert decide(op, {"hosts": ["srv1.corp.local"], "enabled": True}, s, DCs(None)).tier == "H"


def test_disabling_nla_escalates():
    s = Settings()
    assert decide(OPS["rdp_set_nla"], {"hosts": ["srv1"], "required": False}, s, DC).tier == "H"
    assert decide(OPS["rdp_set_nla"], {"hosts": ["srv1"], "required": True}, s, DC).tier == "W"


def test_rdp_users_on_dc_escalate():
    s = Settings()
    for name in ("rdp_users_add", "rdp_users_remove"):
        assert decide(OPS[name], {"host": "DC01.corp.local", "members": ["alice"]}, s, DC).tier == "H"
        assert decide(OPS[name], {"host": "srv1", "members": ["alice"]}, s, DC).tier == "W"


def test_session_ops_do_not_escalate():
    s = Settings()
    for name in ("rdp_session_logoff", "rdp_session_disconnect", "rdp_session_message"):
        assert decide(OPS[name], {"host": "dc01", "session_id": 2, "message": "hi"}, s, DC).tier == "W"


def test_rdp_file_and_uri():
    text = rdp_file("srv1.corp.local", "CORP\\alice", "rdgw.corp.example")
    assert text.endswith("\r\n")
    lines = text.split("\r\n")
    assert "full address:s:srv1.corp.local" in lines
    assert "username:s:CORP\\alice" in lines
    assert "gatewayhostname:s:rdgw.corp.example" in lines
    assert rdp_uri("srv1.corp.local", "CORP\\alice") == "rdp://full%20address=s:srv1.corp.local&username=s:CORP%5Calice"


def test_rdp_file_strips_line_breaks():
    text = rdp_file("srv1", "alice\r\nalternate shell:s:cmd.exe")
    assert "alternate shell:s:cmd.exe" not in text.split("\r\n")


def test_connect_file_post():
    out = OPS["rdp_connect_file"].post({"host": "SRV1.corp.local"}, {"host": "srv1", "username": "alice"}, Settings())
    assert out["filename"] == "srv1.rdp"
    assert out["uri"] == "rdp://full%20address=s:SRV1.corp.local&username=s:alice"
    assert "full address:s:SRV1.corp.local" in out["content"]


def test_host_maps_to_computer_name_and_search_base_is_injected():
    assert ps_params(OPS["rdp_session_logoff"], {"host": "SRV1", "session_id": 3}) == {"ComputerName": "SRV1", "SessionId": 3}
    s = Settings(server_search_base="OU=Servers,DC=corp,DC=local")
    for name in ("rdp_sessions", "rdp_host_status"):
        assert OPS[name].inject(s) == {"ServerSearchBase": "OU=Servers,DC=corp,DC=local"}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_ops_rdp.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'sysadmin.ops.rdp'`

- [ ] **Step 3: Implement** — `sysadmin/ops/rdp.py`

```python
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
```

`sysadmin/ops/__init__.py`:
```python
"""Importing this package registers every operation in sysadmin.registry.OPS."""

from . import domain, gpo, rdp, users  # noqa: F401
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.venv/bin/pytest tests/test_ops_rdp.py`
Expected: `32 passed`

- [ ] **Step 5: Commit**

```bash
git add sysadmin/ops/rdp.py sysadmin/ops/__init__.py tests/test_ops_rdp.py
git commit -m "feat: RDP operations

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Prelude helpers and RDP scripts

**Files:**
- Modify: `sysadmin/scripts/_prelude.ps1` (append two helpers after `Get-HermesFanout`)
- Create (10): `sysadmin/scripts/rdp_sessions.ps1`, `rdp_host_status.ps1`, `rdp_connect_file.ps1`, `rdp_session_logoff.ps1`, `rdp_session_disconnect.ps1`, `rdp_session_message.ps1`, `rdp_set_enabled.ps1`, `rdp_set_nla.ps1`, `rdp_users_add.ps1`, `rdp_users_remove.ps1`
- Modify: `plugin.yaml` (`provides_tools`)

**Interfaces:**
- Produces (prelude, used again in Phase 6): `Get-HermesTargets -Computers <string[]> -Ou <dn> -SearchBase <dn>` → unique DNS names (explicit computers, plus enabled computers in the OU; when both are empty, every enabled server under `SearchBase` or the whole domain; capped at 200). `Invoke-HermesOne -Computer <name> -Script <sb> -ArgumentList <object[]>` → the single fan-out result (hashtable with `host`), throwing on failure.

- [ ] **Step 1: Append to `_prelude.ps1`**

```powershell
function Global:Get-HermesTargets {
    param(
        [string[]]$Computers = @(),
        [string]$Ou,
        [string]$SearchBase
    )
    $t = @($Computers | Where-Object { $_ })
    if ($Ou) {
        $t += @(Get-ADComputer -Filter "Enabled -eq 'True'" -SearchBase $Ou -Properties DNSHostName | ForEach-Object { $_.DNSHostName } | Where-Object { $_ })
    }
    if ($t.Count -eq 0) {
        $splat = @{ Filter = "OperatingSystem -like '*Server*' -and Enabled -eq 'True'"; Properties = 'DNSHostName' }
        if ($SearchBase) { $splat.SearchBase = $SearchBase }
        $t = @(Get-ADComputer @splat | ForEach-Object { $_.DNSHostName } | Where-Object { $_ })
    }
    return @($t | Sort-Object -Unique | Select-Object -First 200)
}

function Global:Invoke-HermesOne {
    param(
        [Parameter(Mandatory)][string]$Computer,
        [Parameter(Mandatory)][scriptblock]$Script,
        [object[]]$ArgumentList = @()
    )
    $r = Get-HermesFanout -Computers @($Computer) -Script $Script -ArgumentList $ArgumentList
    if ($r.errors.Count -gt 0) { throw "$($r.errors[0].host): $($r.errors[0].message)" }
    if ($r.results.Count -eq 0) { throw "$Computer returned no result." }
    return $r.results[0]
}
```

- [ ] **Step 2: Write the scripts**

`rdp_sessions.ps1`:
```powershell
param(
    [string[]]$Hosts = @(),
    [string]$Ou,
    [string]$User,              # filtered in Python (post)
    [string]$ServerSearchBase
)
Invoke-Op {
    $targets = @(Get-HermesTargets -Computers $Hosts -Ou $Ou -SearchBase $ServerSearchBase)
    Assert-Hermes ($targets.Count -gt 0) 'No target computers found.'
    $remote = Get-HermesFanout -Computers $targets -Script {
        [pscustomobject]@{ lines = @(& quser.exe 2>&1 | ForEach-Object { "$_" }) }
    }
    @{
        hosts   = @($remote.results | ForEach-Object { @{ host = $_.host; lines = @($_.lines) } })
        errors  = $remote.errors
        targets = $targets.Count
    }
}
```

`rdp_host_status.ps1`:
```powershell
param(
    [string[]]$Hosts = @(),
    [string]$Ou,
    [string]$ServerSearchBase
)
Invoke-Op {
    $targets = @(Get-HermesTargets -Computers $Hosts -Ou $Ou -SearchBase $ServerSearchBase)
    Assert-Hermes ($targets.Count -gt 0) 'No target computers found.'
    $remote = Get-HermesFanout -Computers $targets -Script {
        $ts = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
        $tcp = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
        # '@FirewallAPI.dll,-28752' is the locale-independent name of the "Remote Desktop" rule group.
        $fw = @(Get-NetFirewallRule -Group '@FirewallAPI.dll,-28752' -ErrorAction SilentlyContinue)
        $members = $null
        try { $members = @(Get-LocalGroupMember -SID 'S-1-5-32-555' -ErrorAction Stop | ForEach-Object { "$($_.Name)" }) } catch { $members = $null }
        $os = Get-CimInstance Win32_OperatingSystem
        [pscustomobject]@{
            enabled       = ($ts.fDenyTSConnections -eq 0)
            nla           = ($tcp.UserAuthentication -eq 1)
            port          = [int]$tcp.PortNumber
            firewall_open = (@($fw | Where-Object { "$($_.Enabled)" -eq 'True' }).Count -gt 0)
            rdp_users     = $members
            os            = "$($os.Caption)"
            last_boot     = $os.LastBootUpTime.ToUniversalTime().ToString('o')
        }
    }
    @{ results = $remote.results; errors = $remote.errors; targets = $targets.Count }
}
```

`rdp_connect_file.ps1`:
```powershell
param(
    [Parameter(Mandatory)][string]$ComputerName,
    [string]$Username,          # used in Python (post)
    [string]$Gateway            # used in Python (post)
)
Invoke-Op {
    $short = $ComputerName.Split('.')[0]
    $c = Get-ADComputer -LDAPFilter "(name=$(ConvertTo-LdapValue $short))" -Properties DNSHostName | Select-Object -First 1
    Assert-Hermes ($null -ne $c) "No computer named '$short' in Active Directory."
    @{ host = $(if ($c.DNSHostName) { $c.DNSHostName } else { $ComputerName }); computer = $c.Name }
}
```

`rdp_session_logoff.ps1`:
```powershell
param(
    [Parameter(Mandatory)][string]$ComputerName,
    [Parameter(Mandatory)][int]$SessionId,
    [switch]$Preview
)
Invoke-Op {
    if ($Preview) {
        $r = Invoke-HermesOne -Computer $ComputerName -Script {
            [pscustomobject]@{ lines = @(& quser.exe 2>&1 | ForEach-Object { "$_" }) }
        }
        return @{
            summary = "Log off session $SessionId on $ComputerName (unsaved work in that session is lost)"
            changes = @("logoff.exe $SessionId")
            current = @{ sessions = @($r.lines) }
        }
    }
    $r = Invoke-HermesOne -Computer $ComputerName -ArgumentList @($SessionId) -Script {
        param($Id)
        $out = (& logoff.exe $Id 2>&1 | Out-String).Trim()
        [pscustomobject]@{ ok = ($LASTEXITCODE -eq 0); output = $out }
    }
    if (-not $r.ok) { throw "logoff failed on ${ComputerName}: $($r.output)" }
    @{ host = $ComputerName; session_id = $SessionId; logged_off = $true }
}
```

`rdp_session_disconnect.ps1`:
```powershell
param(
    [Parameter(Mandatory)][string]$ComputerName,
    [Parameter(Mandatory)][int]$SessionId
)
Invoke-Op {
    $r = Invoke-HermesOne -Computer $ComputerName -ArgumentList @($SessionId) -Script {
        param($Id)
        $out = (& tsdiscon.exe $Id 2>&1 | Out-String).Trim()
        [pscustomobject]@{ ok = ($LASTEXITCODE -eq 0); output = $out }
    }
    if (-not $r.ok) { throw "tsdiscon failed on ${ComputerName}: $($r.output)" }
    @{ host = $ComputerName; session_id = $SessionId; disconnected = $true }
}
```

`rdp_session_message.ps1`:
```powershell
param(
    [Parameter(Mandatory)][string]$ComputerName,
    [Parameter(Mandatory)][string]$Message,
    [Nullable[int]]$SessionId = $null,
    [int]$Seconds = 60
)
Invoke-Op {
    Assert-Hermes ($Message.Length -le 255) 'Message must be 255 characters or fewer.'
    $target = if ($null -ne $SessionId) { "$SessionId" } else { '*' }
    # Arguments are passed as separate argv entries, never through a shell.
    $r = Invoke-HermesOne -Computer $ComputerName -ArgumentList @($target, $Seconds, $Message) -Script {
        param($T, $S, $M)
        $out = (& msg.exe $T "/TIME:$S" $M 2>&1 | Out-String).Trim()
        [pscustomobject]@{ ok = ($LASTEXITCODE -eq 0); output = $out }
    }
    if (-not $r.ok) { throw "msg failed on ${ComputerName}: $($r.output)" }
    @{ host = $ComputerName; session = $target; sent = $true }
}
```

`rdp_set_enabled.ps1`:
```powershell
param(
    [Parameter(Mandatory)][string[]]$Hosts,
    [Parameter(Mandatory)][bool]$Enabled,
    [switch]$Preview
)
Invoke-Op {
    $verb = if ($Enabled) { 'Enable' } else { 'Disable' }
    if ($Preview) {
        $remote = Get-HermesFanout -Computers $Hosts -Script {
            $ts = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
            [pscustomobject]@{ enabled = ($ts.fDenyTSConnections -eq 0) }
        }
        return @{
            summary = "$verb Remote Desktop on $($Hosts.Count) host(s)"
            changes = @("fDenyTSConnections = $([int](-not $Enabled))", "$verb-NetFirewallRule -Group 'Remote Desktop'")
            current = @{ hosts = $remote.results; unreachable = $remote.errors }
        }
    }
    $remote = Get-HermesFanout -Computers $Hosts -ArgumentList @($Enabled) -Script {
        param($On)
        Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value ([int](-not $On))
        if ($On) { Enable-NetFirewallRule -Group '@FirewallAPI.dll,-28752' } else { Disable-NetFirewallRule -Group '@FirewallAPI.dll,-28752' }
        [pscustomobject]@{ enabled = [bool]$On }
    }
    @{ results = $remote.results; errors = $remote.errors }
}
```

`rdp_set_nla.ps1`:
```powershell
param(
    [Parameter(Mandatory)][string[]]$Hosts,
    [Parameter(Mandatory)][bool]$Required
)
Invoke-Op {
    $remote = Get-HermesFanout -Computers $Hosts -ArgumentList @($Required) -Script {
        param($On)
        Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -Value ([int][bool]$On)
        [pscustomobject]@{ nla = [bool]$On }
    }
    @{ results = $remote.results; errors = $remote.errors }
}
```

`rdp_users_add.ps1`:
```powershell
param(
    [Parameter(Mandatory)][string]$ComputerName,
    [Parameter(Mandatory)][string[]]$Members
)
Invoke-Op {
    $netbios = (Get-ADDomain).NetBIOSName
    $qualified = @($Members | ForEach-Object { if ($_ -match '\\') { $_ } else { "$netbios\$_" } })
    $short = $ComputerName.Split('.')[0]
    $isDc = @(Get-ADDomainController -Filter * | Where-Object { $_.Name -eq $short }).Count -gt 0
    if ($isDc) {
        # DCs have no local groups: their Remote Desktop Users is the domain's BUILTIN group.
        Add-ADGroupMember -Identity 'S-1-5-32-555' -Members @($Members | ForEach-Object { $_.Split('\')[-1] })
        $now = @(Get-ADGroupMember -Identity 'S-1-5-32-555' | ForEach-Object { "$netbios\$($_.SamAccountName)" })
    } else {
        $r = Invoke-HermesOne -Computer $ComputerName -ArgumentList @(, $qualified) -Script {
            param($M)
            foreach ($x in $M) {
                try { Add-LocalGroupMember -SID 'S-1-5-32-555' -Member $x -ErrorAction Stop }
                catch [Microsoft.PowerShell.Commands.MemberExistsException] { }
            }
            [pscustomobject]@{ members = @(Get-LocalGroupMember -SID 'S-1-5-32-555' | ForEach-Object { "$($_.Name)" }) }
        }
        $now = @($r.members)
    }
    @{ host = $ComputerName; added = $qualified; domain_controller = $isDc; members = $now }
}
```

`rdp_users_remove.ps1`:
```powershell
param(
    [Parameter(Mandatory)][string]$ComputerName,
    [Parameter(Mandatory)][string[]]$Members
)
Invoke-Op {
    $netbios = (Get-ADDomain).NetBIOSName
    $qualified = @($Members | ForEach-Object { if ($_ -match '\\') { $_ } else { "$netbios\$_" } })
    $short = $ComputerName.Split('.')[0]
    $isDc = @(Get-ADDomainController -Filter * | Where-Object { $_.Name -eq $short }).Count -gt 0
    if ($isDc) {
        Remove-ADGroupMember -Identity 'S-1-5-32-555' -Members @($Members | ForEach-Object { $_.Split('\')[-1] }) -Confirm:$false
        $now = @(Get-ADGroupMember -Identity 'S-1-5-32-555' | ForEach-Object { "$netbios\$($_.SamAccountName)" })
    } else {
        $r = Invoke-HermesOne -Computer $ComputerName -ArgumentList @(, $qualified) -Script {
            param($M)
            foreach ($x in $M) {
                try { Remove-LocalGroupMember -SID 'S-1-5-32-555' -Member $x -ErrorAction Stop }
                catch [Microsoft.PowerShell.Commands.MemberNotFoundException] { }
            }
            [pscustomobject]@{ members = @(Get-LocalGroupMember -SID 'S-1-5-32-555' | ForEach-Object { "$($_.Name)" }) }
        }
        $now = @($r.members)
    }
    @{ host = $ComputerName; removed = $qualified; domain_controller = $isDc; members = $now }
}
```

- [ ] **Step 3: Update `plugin.yaml` `provides_tools`** — append (keep the list sorted):

```yaml
  - rdp_connect_file
  - rdp_host_status
  - rdp_session_disconnect
  - rdp_session_logoff
  - rdp_session_message
  - rdp_sessions
  - rdp_set_enabled
  - rdp_set_nla
  - rdp_users_add
  - rdp_users_remove
```

- [ ] **Step 4: Run the suite**

Run: `.venv/bin/pytest`
Expected: all pass. The contract test now covers the 10 RDP scripts, including the `$ComputerName` mapping and the injected `$ServerSearchBase`; the pwsh parse check also covers the edited prelude.

- [ ] **Step 5: Live smoke** — use a member server with WinRM enabled, plus a test user who has an RDP session on it.

```bash
SRV='<member server FQDN>'
.venv/bin/python scripts/smoke.py rdp_sessions
.venv/bin/python scripts/smoke.py rdp_sessions "{\"hosts\": [\"$SRV\"]}"
.venv/bin/python scripts/smoke.py rdp_host_status "{\"hosts\": [\"$SRV\"]}"
.venv/bin/python scripts/smoke.py rdp_connect_file "{\"host\": \"$SRV\", \"username\": \"zz-hermes-test-1\"}"
.venv/bin/python scripts/smoke.py rdp_users_add "{\"host\": \"$SRV\", \"members\": [\"zz-hermes-test-1\"]}" --approve
.venv/bin/python scripts/smoke.py rdp_session_message "{\"host\": \"$SRV\", \"message\": \"Hermes smoke test\"}" --approve
.venv/bin/python scripts/smoke.py rdp_session_logoff "{\"host\": \"$SRV\", \"session_id\": <id from rdp_sessions>}" --preview
.venv/bin/python scripts/smoke.py rdp_users_remove "{\"host\": \"$SRV\", \"members\": [\"zz-hermes-test-1\"]}" --approve
.venv/bin/python scripts/smoke.py rdp_set_enabled "{\"hosts\": [\"$SRV\"], \"enabled\": true}" --preview
```
Replace `<member server FQDN>` and `<id from rdp_sessions>` with real values before running. Expected: all `"ok": true`. The no-argument `rdp_sessions` scans every enabled server, and unreachable ones appear under `errors` rather than failing the call. `rdp_connect_file` returns `content` that opens in Windows App / mstsc.

- [ ] **Step 6: Commit**

```bash
git add sysadmin/scripts plugin.yaml
git commit -m "feat: RDP PowerShell scripts and fan-out target helpers

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
