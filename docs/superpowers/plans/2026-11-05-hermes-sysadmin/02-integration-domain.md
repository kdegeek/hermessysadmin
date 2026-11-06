# Phase 2 — Hermes integration and domain ops (first vertical slice)

> Part of the [Hermes Sysadmin plan](README.md). Requires Phase 1.

**Deliverable:** an installable plugin that registers the domain tools and approval hooks, passes `hermes plugins validate`, and answers `ad_domain_overview` against the real DC.

**Pattern every later surface phase repeats:** (1) add `Op` entries to `sysadmin/ops/<surface>.py`, (2) add one `.ps1` per op, (3) import the module in `sysadmin/ops/__init__.py`, (4) append tool names to `plugin.yaml` `provides_tools`, (5) unit-test any `post`/`escalate` logic, (6) contract + parse checks, (7) live smoke.

---

### Task 1: Domain ops and scripts

**Files:**
- Create: `sysadmin/ops/domain.py`, `sysadmin/scripts/ad_dc_list.ps1`, `sysadmin/scripts/ad_domain_overview.ps1`, `sysadmin/scripts/ad_dc_health.ps1`, `sysadmin/scripts/ad_search.ps1`, `sysadmin/scripts/ad_connection_test.ps1`
- Modify: `sysadmin/ops/__init__.py`
- Test: `tests/test_ops_domain.py`

**Interfaces:**
- Consumes: `Op`, `Param`, `register`, `is_privileged_group`, `normalize_identity`.
- Produces ops (toolset `ad_domain`, all tier R): `ad_dc_list` (cache 300 s; `{domain, forest, items:[{name, hostname, site, ipv4, os, is_global_catalog, is_read_only, roles}]}`), `ad_domain_overview` (cache 60 s), `ad_dc_health` (cache 60 s; post adds `status` per DC and overall), `ad_search`, `ad_connection_test` (post adds `privileged_memberships`, `warnings`). Python helpers `dc_status(dc) -> "ok"|"warn"|"bad"`, `worst(statuses) -> str`.

- [ ] **Step 1: Write the failing test** — `tests/test_ops_domain.py`

```python
import pytest

from sysadmin import ops  # noqa: F401
from sysadmin.config import Settings
from sysadmin.ops.domain import dc_status, worst
from sysadmin.registry import OPS, coerce_args

HEALTHY = {
    "reachable": True,
    "services": {"NTDS": "Running", "Netlogon": "Running", "KDC": "Running", "DNS": "Running", "W32Time": "Running"},
    "sysvol_shared": True,
    "netlogon_shared": True,
    "time_skew_seconds": 0.4,
    "replication": {"failures": 0},
}


def with_(**changes):
    dc = {**HEALTHY, **changes}
    return dc


@pytest.mark.parametrize(
    "dc, expected",
    [
        (HEALTHY, "ok"),
        (with_(reachable=False), "bad"),
        (with_(services={**HEALTHY["services"], "NTDS": "Stopped"}), "bad"),
        (with_(services={**HEALTHY["services"], "DNS": "Missing"}), "ok"),
        (with_(services={**HEALTHY["services"], "DNS": "Stopped"}), "warn"),
        (with_(services={**HEALTHY["services"], "W32Time": "Stopped"}), "warn"),
        (with_(sysvol_shared=False), "bad"),
        (with_(time_skew_seconds=-75), "warn"),
        (with_(time_skew_seconds=301), "bad"),
        (with_(replication={"failures": 2}), "warn"),
    ],
)
def test_dc_status(dc, expected):
    assert dc_status(dc) == expected


def test_worst():
    assert worst(["ok", "warn", "ok"]) == "warn"
    assert worst(["ok", "bad", "warn"]) == "bad"
    assert worst([]) == "ok"


def test_dc_health_post_adds_status():
    post = OPS["ad_dc_health"].post
    data = post({"items": [HEALTHY, with_(replication={"failures": 1})], "errors": []}, {}, Settings())
    assert [d["status"] for d in data["items"]] == ["ok", "warn"]
    assert data["status"] == "warn"


def test_dc_health_post_marks_unreachable_hosts_bad():
    post = OPS["ad_dc_health"].post
    data = post({"items": [HEALTHY], "errors": [{"host": "dc02", "message": "WinRM cannot complete"}]}, {}, Settings())
    assert data["status"] == "bad"


def test_connection_test_post_flags_privileged_groups_and_warnings():
    post = OPS["ad_connection_test"].post
    data = post(
        {"is_domain_controller": False, "groups": ["CORP\\Domain Admins", "CORP\\Staff"],
         "modules": {"ActiveDirectory": True, "GroupPolicy": False, "WindowsServerBackup": False}},
        {}, Settings(),
    )
    assert data["privileged_memberships"] == ["CORP\\Domain Admins"]
    assert any("not a domain controller" in w for w in data["warnings"])
    assert any("GroupPolicy" in w for w in data["warnings"])


def test_search_args():
    op = OPS["ad_search"]
    assert coerce_args(op, {"query": "bob"}) == {"query": "bob", "kind": "any", "limit": 25}


def test_domain_ops_are_read_only_and_cached_where_expected():
    for name in ("ad_dc_list", "ad_domain_overview", "ad_dc_health", "ad_search", "ad_connection_test"):
        assert OPS[name].tier == "R" and OPS[name].toolset == "ad_domain"
    assert OPS["ad_dc_list"].cache_ttl == 300
    assert OPS["ad_domain_overview"].cache_ttl == 60
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_ops_domain.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'sysadmin.ops.domain'`

- [ ] **Step 3: Implement** — `sysadmin/ops/domain.py`

```python
"""Domain-wide visibility ops: DCs, health, overview counts, search, connection test."""

from __future__ import annotations

from typing import Any, Mapping

from ..policy import is_privileged_group
from ..registry import Op, Param, register

TOOLSET = "ad_domain"
_RANK = {"ok": 0, "warn": 1, "bad": 2}
_REQUIRED_SERVICES = ("NTDS", "Netlogon", "KDC")


def worst(statuses: list[str]) -> str:
    return max(statuses, key=lambda s: _RANK.get(s, 2), default="ok")


def dc_status(dc: Mapping[str, Any]) -> str:
    if not dc.get("reachable"):
        return "bad"
    services = dc.get("services") or {}
    if any(services.get(name) != "Running" for name in _REQUIRED_SERVICES):
        return "bad"
    if dc.get("sysvol_shared") is False or dc.get("netlogon_shared") is False:
        return "bad"
    skew = dc.get("time_skew_seconds")
    if isinstance(skew, (int, float)) and abs(skew) >= 300:
        return "bad"
    status = "ok"
    if services.get("DNS") not in ("Running", "Missing", None):
        status = "warn"
    if services.get("W32Time") not in ("Running", None):
        status = "warn"
    if isinstance(skew, (int, float)) and abs(skew) >= 60:
        status = "warn"
    if (dc.get("replication") or {}).get("failures"):
        status = "warn"
    return status


def _post_dc_health(data: Any, args: Mapping[str, Any], settings: Any) -> Any:
    items = []
    for dc in (data or {}).get("items") or []:
        items.append({**dc, "status": dc_status(dc)})
    errors = (data or {}).get("errors") or []
    overall = worst([d["status"] for d in items] + (["bad"] if errors else []))
    return {"items": items, "errors": errors, "status": overall}


def _post_connection_test(data: Any, args: Mapping[str, Any], settings: Any) -> Any:
    data = dict(data or {})
    groups = [str(g) for g in data.get("groups") or []]
    data["privileged_memberships"] = [g for g in groups if is_privileged_group(g, settings)]
    modules = data.get("modules") or {}
    warnings = []
    if not data.get("is_domain_controller"):
        warnings.append(
            "The jump host is not a domain controller; GPO operations will fail because "
            "GroupPolicy cmdlets cannot use explicit credentials (double hop). Use a DC as the jump host."
        )
    for name in ("ActiveDirectory", "GroupPolicy"):
        if not modules.get(name):
            warnings.append(f"The {name} PowerShell module is not installed on the jump host.")
    data["warnings"] = warnings
    return data


register(Op(
    name="ad_dc_list",
    toolset=TOOLSET,
    tier="R",
    script="ad_dc_list",
    description="List the domain controllers with site, IP, OS, global-catalog/RODC flags and FSMO roles.",
    cache_ttl=300,
))

register(Op(
    name="ad_domain_overview",
    toolset=TOOLSET,
    tier="R",
    script="ad_domain_overview",
    description=(
        "Domain summary: functional levels, FSMO role holders, Recycle Bin state, and counts of users "
        "(enabled, disabled, locked, passwords expiring soon), computers (stale), groups, OUs and GPOs."
    ),
    params=(
        Param("stale_days", "integer", "Computers with no logon for this many days count as stale.", default=90, minimum=1),
        Param("expiring_days", "integer", "Passwords expiring within this many days count as expiring.", default=7, minimum=1),
    ),
    cache_ttl=60,
))

register(Op(
    name="ad_dc_health",
    toolset=TOOLSET,
    tier="R",
    script="ad_dc_health",
    description=(
        "Health of every domain controller: reachability, NTDS/DNS/Netlogon/KDC/W32Time service state, "
        "SYSVOL/NETLOGON shares, uptime, time skew and replication failures, with an ok/warn/bad status."
    ),
    post=_post_dc_health,
    cache_ttl=60,
))

register(Op(
    name="ad_search",
    toolset=TOOLSET,
    tier="R",
    script="ad_search",
    description=(
        "Search AD objects by name (ambiguous name resolution) or by a raw LDAP filter starting with '('. "
        "Returns name, DN, class, sAMAccountName and description."
    ),
    params=(
        Param("query", "string", "Name fragment, sAMAccountName, or an LDAP filter like (mail=*@corp.com).", required=True),
        Param("kind", "string", "Restrict to one object class.", enum=("any", "user", "group", "computer", "ou"), default="any"),
        Param("limit", "integer", "Maximum results.", default=25, minimum=1),
    ),
))

register(Op(
    name="ad_connection_test",
    toolset=TOOLSET,
    tier="R",
    script="ad_connection_test",
    description=(
        "Test the WinRM connection to the jump host: OS, whether it is a DC, PowerShell modules present, "
        "the identity in use and its privileged group memberships, plus setup warnings."
    ),
    post=_post_connection_test,
))
```

`sysadmin/ops/__init__.py`:
```python
"""Importing this package registers every operation in sysadmin.registry.OPS."""

from . import domain  # noqa: F401
```

- [ ] **Step 4: Write the scripts**

`sysadmin/scripts/ad_dc_list.ps1`:
```powershell
param()
Invoke-Op {
    $domain = Get-ADDomain
    $forest = Get-ADForest
    $items = @(Get-ADDomainController -Filter * | Sort-Object Name | ForEach-Object {
        @{
            name              = $_.Name
            hostname          = $_.HostName
            site              = $_.Site
            ipv4              = $_.IPv4Address
            os                = $_.OperatingSystem
            is_global_catalog = [bool]$_.IsGlobalCatalog
            is_read_only      = [bool]$_.IsReadOnly
            roles             = @($_.OperationMasterRoles | ForEach-Object { "$_" })
        }
    })
    @{ domain = $domain.DNSRoot; forest = $forest.Name; items = $items }
}
```

`sysadmin/scripts/ad_domain_overview.ps1`:
```powershell
param(
    [int]$StaleDays = 90,
    [int]$ExpiringDays = 7
)
Invoke-Op {
    $d = Get-ADDomain
    $f = Get-ADForest
    $nowUtc = (Get-Date).ToUniversalTime()
    $users = @(Get-ADUser -Filter * -Properties Enabled, PasswordNeverExpires, 'msDS-UserPasswordExpiryTimeComputed')
    $locked = @(Search-ADAccount -LockedOut -UsersOnly)
    $expiring = @($users | Where-Object {
        $ft = $_.'msDS-UserPasswordExpiryTimeComputed'
        $_.Enabled -and -not $_.PasswordNeverExpires -and $ft -gt 0 -and $ft -lt [long]::MaxValue -and
        [datetime]::FromFileTimeUtc($ft) -gt $nowUtc -and [datetime]::FromFileTimeUtc($ft) -lt $nowUtc.AddDays($ExpiringDays)
    })
    $computers = @(Get-ADComputer -Filter * -Properties LastLogonTimestamp)
    $cutoff = $nowUtc.AddDays(-$StaleDays).ToFileTimeUtc()
    $stale = @($computers | Where-Object { -not $_.LastLogonTimestamp -or $_.LastLogonTimestamp -lt $cutoff })
    $gpos = $null
    if (Get-Command Get-GPO -ErrorAction SilentlyContinue) { $gpos = @(Get-GPO -All).Count }
    $recycle = @(Get-ADOptionalFeature -Filter "Name -eq 'Recycle Bin Feature'" | Where-Object { $_.EnabledScopes.Count -gt 0 }).Count -gt 0
    @{
        domain              = $d.DNSRoot
        netbios             = $d.NetBIOSName
        domain_mode         = "$($d.DomainMode)"
        forest              = $f.Name
        forest_mode         = "$($f.ForestMode)"
        fsmo                = @{ pdc = $d.PDCEmulator; rid = $d.RIDMaster; infrastructure = $d.InfrastructureMaster; schema = $f.SchemaMaster; naming = $f.DomainNamingMaster }
        recycle_bin_enabled = $recycle
        stale_days          = $StaleDays
        expiring_days       = $ExpiringDays
        counts              = @{
            users              = $users.Count
            users_enabled      = @($users | Where-Object { $_.Enabled }).Count
            users_disabled     = @($users | Where-Object { -not $_.Enabled }).Count
            users_locked       = $locked.Count
            passwords_expiring = $expiring.Count
            computers          = $computers.Count
            computers_stale    = $stale.Count
            groups             = @(Get-ADGroup -Filter *).Count
            ous                = @(Get-ADOrganizationalUnit -Filter *).Count
            gpos               = $gpos
        }
    }
}
```

`sysadmin/scripts/ad_dc_health.ps1`:
```powershell
param()
Invoke-Op {
    $dcs = @(Get-ADDomainController -Filter * | Sort-Object Name)
    $refUtc = [datetime]::UtcNow
    $remote = Get-HermesFanout -Computers @($dcs | ForEach-Object { $_.HostName }) -Script {
        $svc = @{}
        foreach ($n in 'NTDS', 'DNS', 'Netlogon', 'KDC', 'W32Time') {
            $s = Get-Service -Name $n -ErrorAction SilentlyContinue
            $svc[$n] = if ($s) { "$($s.Status)" } else { 'Missing' }
        }
        $os = Get-CimInstance Win32_OperatingSystem
        [pscustomobject]@{
            services        = $svc
            uptime_hours    = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
            utc_now         = [datetime]::UtcNow.ToString('o')
            sysvol_shared   = [bool](Get-SmbShare -Name SYSVOL -ErrorAction SilentlyContinue)
            netlogon_shared = [bool](Get-SmbShare -Name NETLOGON -ErrorAction SilentlyContinue)
        }
    }
    $byHost = @{}
    foreach ($r in $remote.results) { $byHost["$($r.host)".ToLower()] = $r }
    $items = @(foreach ($dc in $dcs) {
        $failures = @(Get-ADReplicationFailure -Target $dc.HostName -ErrorAction SilentlyContinue | Where-Object { $_.FailureCount -gt 0 })
        $partners = @(Get-ADReplicationPartnerMetadata -Target $dc.HostName -Scope Server -ErrorAction SilentlyContinue)
        $last = ($partners | Sort-Object LastReplicationSuccess -Descending | Select-Object -First 1).LastReplicationSuccess
        $r = $byHost["$($dc.HostName)".ToLower()]
        if (-not $r) { $r = $byHost["$($dc.Name)".ToLower()] }
        $skew = $null
        if ($r -and $r.utc_now) { $skew = [math]::Round((([datetime]$r.utc_now).ToUniversalTime() - $refUtc).TotalSeconds, 1) }
        @{
            name              = $dc.Name
            hostname          = $dc.HostName
            site              = $dc.Site
            roles             = @($dc.OperationMasterRoles | ForEach-Object { "$_" })
            reachable         = [bool]$r
            services          = $(if ($r) { $r.services } else { $null })
            uptime_hours      = $(if ($r) { $r.uptime_hours } else { $null })
            sysvol_shared     = $(if ($r) { $r.sysvol_shared } else { $null })
            netlogon_shared   = $(if ($r) { $r.netlogon_shared } else { $null })
            time_skew_seconds = $skew
            replication       = @{
                failures     = $failures.Count
                partners     = $partners.Count
                last_success = (Iso $last)
                errors       = @($failures | Select-Object -First 5 | ForEach-Object {
                    @{ partner = "$($_.Partner)"; count = $_.FailureCount; first = (Iso $_.FirstFailureTime); message = "$($_.LastError)" }
                })
            }
        }
    })
    @{ items = $items; errors = $remote.errors }
}
```

`sysadmin/scripts/ad_search.ps1`:
```powershell
param(
    [Parameter(Mandatory)][string]$Query,
    [ValidateSet('any', 'user', 'group', 'computer', 'ou')][string]$Kind = 'any',
    [int]$Limit = 25
)
Invoke-Op {
    if ($Query.TrimStart().StartsWith('(')) {
        $filter = $Query
    } else {
        $escaped = $Query -replace '\\', '\5c' -replace '\(', '\28' -replace '\)', '\29' -replace "`0", '\00'
        $filter = "(anr=$escaped)"
    }
    $classFilter = switch ($Kind) {
        'user' { '(&(objectCategory=person)(objectClass=user))' }
        'group' { '(objectClass=group)' }
        'computer' { '(objectClass=computer)' }
        'ou' { '(objectClass=organizationalUnit)' }
        default { $null }
    }
    if ($classFilter) { $filter = "(&$classFilter$filter)" }
    $items = @(Get-ADObject -LDAPFilter $filter -ResultSetSize $Limit -Properties sAMAccountName, displayName, description, whenChanged | ForEach-Object {
        @{
            name         = $_.Name
            dn           = $_.DistinguishedName
            class        = $_.ObjectClass
            sam          = $_.sAMAccountName
            display_name = $_.displayName
            description  = "$($_.description)"
            changed      = (Iso $_.whenChanged)
        }
    })
    @{ items = $items; filter = $filter; truncated = ($items.Count -ge $Limit) }
}
```

`sysadmin/scripts/ad_connection_test.ps1`:
```powershell
param()
Invoke-Op {
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $groups = @($id.Groups | ForEach-Object {
        try { $_.Translate([System.Security.Principal.NTAccount]).Value } catch { $null }
    } | Where-Object { $_ })
    @{
        hostname             = $env:COMPUTERNAME
        os                   = $os.Caption
        os_version           = $os.Version
        domain               = $cs.Domain
        is_domain_controller = ($cs.DomainRole -ge 4)
        ps_version           = "$($PSVersionTable.PSVersion)"
        identity             = $id.Name
        groups               = $groups
        modules              = @{
            ActiveDirectory     = [bool](Get-Module -ListAvailable -Name ActiveDirectory)
            GroupPolicy         = [bool](Get-Module -ListAvailable -Name GroupPolicy)
            WindowsServerBackup = [bool](Get-Module -ListAvailable -Name WindowsServerBackup)
        }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `.venv/bin/pytest tests/test_ops_domain.py`
Expected: `16 passed`

- [ ] **Step 6: Commit**

```bash
git add sysadmin/ops sysadmin/scripts tests/test_ops_domain.py
git commit -m "feat: domain visibility ops

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Script contract lint and PowerShell parse check

**Files:**
- Create: `tests/test_scripts_contract.py`, `scripts/ps_parse_check.ps1`

**Interfaces:**
- Consumes: `OPS`, `SCRIPTS_DIR`.
- Produces: a contract test every later phase relies on (new scripts are checked automatically).

- [ ] **Step 1: Install pwsh (one-time)**

Run: `brew install --cask powershell && pwsh -v`
Expected: `PowerShell 7.x.x`

- [ ] **Step 2: Write the contract test** — `tests/test_scripts_contract.py`

```python
import re
import shutil
import subprocess
from pathlib import Path

import pytest

from sysadmin import ops  # noqa: F401
from sysadmin.registry import OPS
from sysadmin.runner import SCRIPTS_DIR

ROOT = Path(__file__).resolve().parent.parent
REAL_OPS = [op for op in OPS.values() if not op.name.startswith("t_")]
FORBIDDEN = re.compile(r"Invoke-Expression|\biex\b|Add-Type|DownloadString|Start-Process", re.IGNORECASE)


def _code(text: str) -> str:
    text = re.sub(r"<#.*?#>", "", text, flags=re.S)
    return "\n".join(line for line in text.splitlines() if not line.strip().startswith("#"))


def _param_block(text: str) -> str:
    code = _code(text).lstrip()
    assert code.lower().startswith("param("), "script must start with a param() block"
    depth = 0
    for i, ch in enumerate(code):
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return code[: i + 1]
    raise AssertionError("unterminated param block")


@pytest.mark.parametrize("op", REAL_OPS, ids=lambda o: o.name)
def test_every_op_has_a_contract_conforming_script(op):
    path = SCRIPTS_DIR / f"{op.script}.ps1"
    assert path.is_file(), f"missing {path.name}"
    text = path.read_text(encoding="utf-8")
    block = _param_block(text)
    assert "Invoke-Op {" in text
    assert not FORBIDDEN.search(_code(text)), "forbidden construct"
    for p in op.params:
        assert re.search(rf"\${p.ps_name}\b", block, re.IGNORECASE), f"param ${p.ps_name} not declared"
    if op.preview:
        assert re.search(r"\[switch\]\$Preview\b", block), "preview ops must declare [switch]$Preview"
    if op.inject is not None:
        from sysadmin.config import Settings

        for name in op.inject(Settings()):
            assert re.search(rf"\${name}\b", block, re.IGNORECASE), f"injected ${name} not declared"


def test_no_orphan_scripts():
    scripts = {p.stem for p in SCRIPTS_DIR.glob("*.ps1")} - {"_prelude"}
    assert scripts == {op.script for op in REAL_OPS}


@pytest.mark.skipif(shutil.which("pwsh") is None, reason="pwsh not installed")
def test_all_scripts_parse():
    result = subprocess.run(
        ["pwsh", "-NoProfile", "-File", str(ROOT / "scripts" / "ps_parse_check.ps1"), "-Path", str(SCRIPTS_DIR)],
        capture_output=True, text=True, timeout=120,
    )
    assert result.returncode == 0, result.stdout + result.stderr
```

`scripts/ps_parse_check.ps1`:
```powershell
param([Parameter(Mandatory)][string]$Path)
$bad = 0
Get-ChildItem -Path $Path -Filter *.ps1 | ForEach-Object {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        $bad++
        foreach ($e in $errors) { Write-Output "$($_.Name):$($e.Extent.StartLineNumber): $($e.Message)" }
    }
}
if ($bad -gt 0) { exit 1 }
Write-Output 'All scripts parse.'
```

- [ ] **Step 3: Run**

Run: `.venv/bin/pytest tests/test_scripts_contract.py -v`
Expected: 5 per-op tests + `test_no_orphan_scripts` + `test_all_scripts_parse` all PASS. If the parse test fails, fix the reported line in the named script and re-run.

- [ ] **Step 4: Commit**

```bash
git add tests/test_scripts_contract.py scripts/ps_parse_check.ps1
git commit -m "test: PowerShell script contract and parse checks

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Agent tools adapter

**Files:**
- Create: `sysadmin/tools.py`
- Test: `tests/test_tools.py`

**Interfaces:**
- Consumes: `runtime.get_service()`, `OPS`, `schema_for`, `load_settings`, `error_result`.
- Produces: `make_handler(name) -> Callable[[dict], str]`, `register_tools(ctx) -> list[str]`, `EMOJI`.

- [ ] **Step 1: Write the failing test** — `tests/test_tools.py`

```python
import json

from sysadmin import ops  # noqa: F401
from sysadmin import runtime, tools
from sysadmin.registry import OPS


class FakeCtx:
    def __init__(self):
        self.tools = {}

    def register_tool(self, **kwargs):
        self.tools[kwargs["name"]] = kwargs


def test_register_tools_registers_every_real_op_with_schema():
    ctx = FakeCtx()
    names = tools.register_tools(ctx)
    real = sorted(n for n in OPS if not n.startswith("t_"))
    assert names == real
    entry = ctx.tools["ad_search"]
    assert entry["toolset"] == "ad_domain"
    assert entry["schema"]["name"] == "ad_search"
    assert entry["emoji"] == "🏢"
    assert callable(entry["handler"])


def test_handler_returns_json_and_marks_agent_actor(monkeypatch, make_service, runner):
    runner.responses["ad_search"] = {"items": []}
    svc = make_service()
    monkeypatch.setattr(runtime, "get_service", lambda: svc)
    out = tools.make_handler("ad_search")({"query": "bob"}, session_id="s1", task_id="t")
    assert json.loads(out) == {"ok": True, "data": {"items": []}}
    assert runner.calls[0][0] == "ad_search"


def test_handler_never_raises(monkeypatch):
    def boom():
        raise RuntimeError("no runtime")

    monkeypatch.setattr(runtime, "get_service", boom)
    out = json.loads(tools.make_handler("ad_search")({"query": "x"}))
    assert out["ok"] is False and out["error"]["type"] == "InternalError"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_tools.py`
Expected: FAIL — `ImportError: cannot import name 'tools'`

- [ ] **Step 3: Implement** — `sysadmin/tools.py`

```python
"""Registers every operation as a Hermes agent tool. Handlers never raise."""

from __future__ import annotations

import json
from typing import Any, Callable

from . import runtime
from .config import load_settings
from .errors import error_result
from .registry import OPS, schema_for

EMOJI = {
    "ad_domain": "🏢",
    "ad_users": "👤",
    "ad_gpo": "📜",
    "ad_rdp": "🖥️",
    "ad_backup": "💾",
    "ad_meta": "🛠️",
}


def make_handler(name: str) -> Callable[..., str]:
    def handler(args: dict | None = None, **kwargs: Any) -> str:
        try:
            service = runtime.get_service()
            session = str(kwargs.get("session_id") or kwargs.get("task_id") or "")
            # The pre_tool_call hook has already obtained any approval Hermes required;
            # Service.call() still re-checks blocks (protected objects, read-only mode).
            result = service.call(name, args or {}, actor="agent", session=session, approved=True)
        except Exception as exc:
            result = error_result(exc)
        return json.dumps(result, default=str, ensure_ascii=False)

    handler.__name__ = f"hermes_sysadmin_{name}"
    return handler


def _escape_enabled() -> bool:
    return load_settings().enable_powershell_escape


def register_tools(ctx: Any) -> list[str]:
    names: list[str] = []
    for op in sorted(OPS.values(), key=lambda o: o.name):
        if op.name.startswith("t_"):
            continue
        ctx.register_tool(
            name=op.name,
            toolset=op.toolset,
            schema=schema_for(op),
            handler=make_handler(op.name),
            check_fn=_escape_enabled if op.name == "ad_powershell" else None,
            description=op.description,
            emoji=EMOJI.get(op.toolset, "🏢"),
        )
        names.append(op.name)
    return names
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.venv/bin/pytest tests/test_tools.py`
Expected: `3 passed`

- [ ] **Step 5: Commit**

```bash
git add sysadmin/tools.py tests/test_tools.py
git commit -m "feat: agent tool adapter

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Approval hooks

**Files:**
- Create: `sysadmin/hooks.py`
- Test: `tests/test_hooks.py`

**Interfaces:**
- Consumes: `runtime.get_service()`, `Service.preview/record_denied/settings/facts`, `decide`, `coerce_args`, `target_of`, `redact`.
- Produces: `pre_tool_call(tool_name="", args=None, **kwargs) -> dict | None`, `post_tool_call(tool_name="", args=None, result=None, status="", **kwargs) -> None`, `format_preview(data) -> str`, `PREFIX = "[hermes-sysadmin]"`.

Behaviour contract:
- R ops and unknown tools → `None`.
- Invalid args → `None` (the handler reports the error and runs nothing).
- Policy `block` → `None` (the handler's `Service.call` blocks and audits it, so blocked attempts are logged exactly once).
- Policy `approve` W → `{"action": "approve", "message": ..., "rule_key": "hermes-sysadmin:<op>"}`.
- Policy `approve` H → message includes the preview; `rule_key` is `"hermes-sysadmin:<op>:once:<uuid>"` so an "always allow" answer can never match a later call.
- Any unexpected exception → still `approve` with a warning message (a human must decide; the handler re-checks blocks).
- `post_tool_call` with `status == "blocked"` for one of our ops → `Service.record_denied(...)`.

- [ ] **Step 1: Write the failing test** — `tests/test_hooks.py`

```python
import pytest

from sysadmin import hooks, runtime
from sysadmin.config import Settings
from sysadmin.registry import Op, Param


@pytest.fixture
def svc(monkeypatch, make_service, scratch_ops):
    p = (Param("identity", "string", "x", required=True),)
    scratch_ops(Op("t_h_read", "t", "R", "t_h_read", "d", params=p))
    scratch_ops(Op("t_h_write", "t", "W", "t_h_write", "d", params=p, identities=("identity",)))
    scratch_ops(Op("t_h_high", "t", "H", "t_h_high", "d", params=p, identities=("identity",), preview=True))
    scratch_ops(Op("t_h_high_np", "t", "H", "t_h_high_np", "d", params=(Param("script", "string", "s", required=True),)))
    service = make_service()
    monkeypatch.setattr(runtime, "get_service", lambda: service)
    return service


def test_read_and_unknown_tools_pass_through(svc):
    assert hooks.pre_tool_call(tool_name="t_h_read", args={"identity": "bob"}) is None
    assert hooks.pre_tool_call(tool_name="terminal", args={"cmd": "ls"}) is None


def test_write_requests_approval_with_stable_rule_key(svc):
    d = hooks.pre_tool_call(tool_name="t_h_write", args={"identity": "bob"}, session_id="s")
    assert d["action"] == "approve"
    assert d["rule_key"] == "hermes-sysadmin:t_h_write"
    assert d["message"].startswith("[hermes-sysadmin] Write: t_h_write → bob")


def test_high_risk_includes_preview_and_unique_rule_key(svc, runner):
    runner.responses["t_h_high"] = {"summary": "Delete bob", "changes": ["remove CN=bob"], "current": {"groups": ["A", "B"]}}
    a = hooks.pre_tool_call(tool_name="t_h_high", args={"identity": "bob"})
    b = hooks.pre_tool_call(tool_name="t_h_high", args={"identity": "bob"})
    assert a["action"] == "approve" and "HIGH-RISK" in a["message"]
    assert "Preview (no change made yet):" in a["message"]
    assert "Delete bob" in a["message"] and "• remove CN=bob" in a["message"] and "groups: A, B" in a["message"]
    assert a["rule_key"].startswith("hermes-sysadmin:t_h_high:once:")
    assert a["rule_key"] != b["rule_key"]


def test_high_risk_without_script_preview_shows_arguments(svc):
    d = hooks.pre_tool_call(tool_name="t_h_high_np", args={"script": "Get-Process"})
    assert "Get-Process" in d["message"]


def test_preview_failure_still_requests_approval(svc, runner):
    from sysadmin.errors import ConnectionFailed

    runner.responses["t_h_high"] = ConnectionFailed("down")
    d = hooks.pre_tool_call(tool_name="t_h_high", args={"identity": "bob"})
    assert d["action"] == "approve" and "unavailable" in d["message"]


def test_blocks_and_bad_args_are_left_to_the_handler(svc):
    assert hooks.pre_tool_call(tool_name="t_h_write", args={"identity": "krbtgt"}) is None
    assert hooks.pre_tool_call(tool_name="t_h_write", args={}) is None


def test_permissive_mode_skips_approval_for_writes(monkeypatch, make_service, svc):
    permissive = make_service(settings=Settings(host="h", username="u", password="p", mode="permissive"))
    monkeypatch.setattr(runtime, "get_service", lambda: permissive)
    assert hooks.pre_tool_call(tool_name="t_h_write", args={"identity": "bob"}) is None
    assert hooks.pre_tool_call(tool_name="t_h_high", args={"identity": "bob"})["action"] == "approve"


def test_unexpected_error_fails_to_approval_not_silence(monkeypatch, svc):
    def boom():
        raise RuntimeError("settings unreadable")

    monkeypatch.setattr(runtime, "get_service", boom)
    d = hooks.pre_tool_call(tool_name="t_h_write", args={"identity": "bob"})
    assert d["action"] == "approve" and "could not evaluate" in d["message"]


def test_post_tool_call_records_denials(svc, audit):
    hooks.post_tool_call(tool_name="t_h_write", args={"identity": "bob"}, result="BLOCKED: denied by user", status="blocked", session_id="s9")
    hooks.post_tool_call(tool_name="t_h_write", args={"identity": "bob"}, result="{}", status="success")
    hooks.post_tool_call(tool_name="terminal", args={}, result="x", status="blocked")
    rows = audit.query()
    assert len(rows) == 1
    assert rows[0]["decision"] == "denied: BLOCKED: denied by user" and rows[0]["session"] == "s9"


def test_format_preview_handles_non_dict():
    assert hooks.format_preview(["a", 1]) == '["a", 1]'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_hooks.py`
Expected: FAIL — `ImportError: cannot import name 'hooks'`

- [ ] **Step 3: Implement** — `sysadmin/hooks.py`

```python
"""pre_tool_call escalates writes to Hermes's human-approval gate; post_tool_call audits denials."""

from __future__ import annotations

import json
import logging
import uuid
from typing import Any

from . import runtime
from .audit import redact
from .errors import InvalidArguments
from .policy import decide
from .registry import OPS, coerce_args, target_of

log = logging.getLogger(__name__)
PREFIX = "[hermes-sysadmin]"


def format_preview(data: Any) -> str:
    if not isinstance(data, dict):
        return json.dumps(data, default=str)[:1500]
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
    return "\n".join(lines)[:1500]


def pre_tool_call(tool_name: str = "", args: dict | None = None, **kwargs: Any) -> dict | None:
    op = OPS.get(tool_name)
    if op is None or op.tier == "R":
        return None
    try:
        service = runtime.get_service()
        try:
            clean = coerce_args(op, args)
        except InvalidArguments:
            return None
        decision = decide(op, clean, service.settings, service.facts)
        if decision.action != "approve":
            return None
        label = "HIGH-RISK" if decision.tier == "H" else "Write"
        lines = [f"{PREFIX} {label}: {op.name} → {target_of(op, clean) or '(no target)'}", decision.reason]
        if decision.needs_preview:
            preview = service.preview(op.name, clean)
            body = format_preview(preview["data"]) if preview.get("ok") else f"unavailable — {preview['error']['message']}"
            lines.append("Preview (no change made yet):\n" + body)
        elif decision.tier == "H":
            lines.append("Arguments:\n" + format_preview({"details": redact(clean)}))
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
            "message": f"{PREFIX} {tool_name}: the safety policy could not evaluate this call ({exc}). "
                       "Approve only if you intended this change.",
            "rule_key": f"hermes-sysadmin:{tool_name}:once:{uuid.uuid4().hex}",
        }


def post_tool_call(tool_name: str = "", args: dict | None = None, result: Any = None, status: str = "", **kwargs: Any) -> None:
    if tool_name not in OPS or str(status).lower() != "blocked":
        return None
    try:
        reason = str(result or "").strip()[:160] or "by user"
        runtime.get_service().record_denied(
            tool_name, args, actor="agent", session=str(kwargs.get("session_id") or ""), reason=reason
        )
    except Exception:
        log.exception("hermes-sysadmin: post_tool_call audit failed")
    return None
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.venv/bin/pytest tests/test_hooks.py`
Expected: `10 passed`

- [ ] **Step 5: Commit**

```bash
git add sysadmin/hooks.py tests/test_hooks.py
git commit -m "feat: approval and denial-audit hooks

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Manifest, register(), and Hermes validation

**Files:**
- Create: `plugin.yaml`, `__init__.py`
- Test: `tests/test_plugin.py`

**Interfaces:**
- Consumes: `tools.register_tools`, `hooks.pre_tool_call`, `hooks.post_tool_call`.
- Produces: `register(ctx)` (root package). `tests/test_plugin.py` helpers `load_plugin()` and `FakeCtx` reused by Phase 7.

- [ ] **Step 1: Write the failing test** — `tests/test_plugin.py`

```python
import importlib.util
import sys
from pathlib import Path

import yaml

from sysadmin import ops  # noqa: F401
from sysadmin.registry import OPS

ROOT = Path(__file__).resolve().parent.parent


def load_plugin():
    name = "hermes_sysadmin_plugin_under_test"
    spec = importlib.util.spec_from_file_location(name, ROOT / "__init__.py", submodule_search_locations=[str(ROOT)])
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


class FakeCtx:
    def __init__(self):
        self.tools, self.hooks, self.skills, self.commands = {}, {}, {}, {}

    def register_tool(self, **kwargs):
        self.tools[kwargs["name"]] = kwargs

    def register_hook(self, name, fn, **kwargs):
        self.hooks[name] = fn

    def register_skill(self, name, path, **kwargs):
        self.skills[name] = Path(path)

    def register_command(self, name, handler, description="", args_hint="", **kwargs):
        self.commands[name] = (handler, description, args_hint)

    def ask_choice(self, question, choices):
        return choices[0]


def manifest():
    return yaml.safe_load((ROOT / "plugin.yaml").read_text(encoding="utf-8"))


def test_manifest_core_fields():
    m = manifest()
    assert m["name"] == "hermes-sysadmin"
    assert m["manifest_version"] == 2
    assert m["requires_hermes"] == ">=0.22.2"
    assert m["python_dependencies"] == ["pypsrp>=0.8.1,<0.9"]
    assert m["config_schema"]["password"] == {
        "type": "secret", "env": "SYSADMIN_WINRM_PASSWORD", "label": "Password",
        "description": "Password for the WinRM account. Stored in Hermes secrets, never in config.yaml.",
        "required": True,
    }
    assert m["config_schema"]["mode"]["choices"] == ["strict", "permissive", "read-only"]


def test_manifest_declares_exactly_what_register_registers():
    ctx = FakeCtx()
    load_plugin().register(ctx)
    m = manifest()
    assert sorted(m["provides_tools"]) == sorted(ctx.tools) == sorted(n for n in OPS if not n.startswith("t_"))
    assert sorted(m["provides_hooks"]) == sorted(ctx.hooks) == ["post_tool_call", "pre_tool_call"]
    assert m["provides_middleware"] == []
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_plugin.py`
Expected: FAIL — `FileNotFoundError: ... plugin.yaml`

- [ ] **Step 3: Implement**

`plugin.yaml`:
```yaml
name: hermes-sysadmin
label: "Sysadmin · Active Directory"
version: 0.1.0
manifest_version: 2
description: >-
  Manage an on-prem Active Directory domain over WinRM: users, groups and lockouts, Group Policy,
  RDP sessions and access, and Windows Server Backup. Typed tools with tiered approvals, protected
  objects, a local audit log, workflow skills, /ad commands and a Hermes Desktop dashboard.
author: Nate Crawford
kind: general
license: MIT
tags: [active-directory, windows, winrm, group-policy, rdp, backup, sysadmin]
requires_hermes: ">=0.22.2"
python_dependencies:
  - "pypsrp>=0.8.1,<0.9"
provides_tools:
  - ad_connection_test
  - ad_dc_health
  - ad_dc_list
  - ad_domain_overview
  - ad_search
provides_hooks:
  - pre_tool_call
  - post_tool_call
provides_middleware: []
config_schema:
  host:
    type: str
    label: Jump host (domain controller)
    description: FQDN of the domain controller Hermes connects to over WinRM, e.g. dc01.corp.example.local.
    required: true
  port:
    type: int
    default: 5986
    label: WinRM port
    description: 5986 for HTTPS, 5985 for HTTP (traffic is still encrypted with NTLM/Kerberos).
  use_https:
    type: bool
    default: true
    label: Use HTTPS
  auth:
    type: str
    choices: [ntlm, kerberos]
    default: ntlm
    label: Authentication
  username:
    type: str
    label: Username
    description: DOMAIN\user or user@domain. Prefer a delegated admin account over a Domain Admin.
    required: true
  password:
    type: secret
    env: SYSADMIN_WINRM_PASSWORD
    label: Password
    description: Password for the WinRM account. Stored in Hermes secrets, never in config.yaml.
    required: true
  verify_tls:
    type: bool
    default: true
    label: Verify TLS certificate
    description: Turn off only for a lab with a self-signed WinRM certificate.
  server_search_base:
    type: str
    default: ""
    label: Servers OU
    description: Distinguished name of the OU searched when an action targets "all servers". Empty means every Windows Server computer object.
  backup_stale_days:
    type: int
    default: 7
    label: Backup stale after (days)
    description: A system-state backup older than this is flagged red.
  mode:
    type: str
    choices: [strict, permissive, read-only]
    default: strict
    label: Safety mode
    description: strict asks before every write; permissive asks only for high-risk changes; read-only blocks all writes.
  protected_objects:
    type: list
    default: []
    label: Protected objects
    description: Extra accounts or groups that can never be changed (krbtgt and Administrator are always protected).
  privileged_groups:
    type: list
    default: []
    label: Extra privileged groups
    description: Groups treated like Domain Admins; membership changes become high-risk.
  enable_powershell_escape:
    type: bool
    default: false
    label: Enable raw PowerShell tool
    description: Registers ad_powershell, which runs arbitrary PowerShell on the jump host after approval every time.
```

`__init__.py`:
```python
"""hermes-sysadmin — Active Directory, Group Policy, RDP and Windows Server Backup over WinRM.

Install:  hermes plugins install <owner>/hermessysadmin --enable
Dev loop: ln -s "$PWD" ~/.hermes/plugins/hermes-sysadmin && hermes plugins enable hermes-sysadmin
"""

from __future__ import annotations


def register(ctx):
    from .sysadmin import hooks, tools

    tools.register_tools(ctx)
    ctx.register_hook("pre_tool_call", hooks.pre_tool_call)
    ctx.register_hook("post_tool_call", hooks.post_tool_call)
```

- [ ] **Step 4: Run tests**

Run: `.venv/bin/pytest`
Expected: all pass.

- [ ] **Step 5: Validate with the installed Hermes**

Run:
```bash
hermes plugins validate "$(git rev-parse --show-toplevel)" --install-deps
hermes plugins doctor "$(git rev-parse --show-toplevel)" --ci
```
Expected: both exit 0 with no errors. Fix any reported drift (declared vs registered tools, config_schema type warnings) in `plugin.yaml` before continuing; re-run both commands until clean.

- [ ] **Step 6: Commit**

```bash
git add plugin.yaml __init__.py tests/test_plugin.py
git commit -m "feat: plugin manifest and register()

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Smoke CLI and first live call

**Files:**
- Create: `scripts/smoke.py`

**Interfaces:**
- Consumes: `settings_from`, `Service`, `Runner`, `PsrpTransport`, `load_prelude`, `open_audit`.
- Produces: `python scripts/smoke.py <op> ['<json args>'] [--approve]` using env vars `SYSADMIN_HOST`, `SYSADMIN_USER`, `SYSADMIN_WINRM_PASSWORD`, optional `SYSADMIN_PORT`, `SYSADMIN_HTTPS`, `SYSADMIN_VERIFY_TLS`. Phase 10 live tests use the same variables.

- [ ] **Step 1: Write** `scripts/smoke.py`

```python
"""Manual smoke test against a real domain, without Hermes.

    export SYSADMIN_HOST=dc01.corp.example.local SYSADMIN_USER='CORP\\svc-hermes'
    read -s SYSADMIN_WINRM_PASSWORD && export SYSADMIN_WINRM_PASSWORD
    .venv/bin/python scripts/smoke.py ad_connection_test
    .venv/bin/python scripts/smoke.py ad_search '{"query": "bob"}'
    .venv/bin/python scripts/smoke.py ad_user_unlock '{"identity": "zz-hermes-test-1"}' --approve
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from sysadmin import ops  # noqa: E402,F401
from sysadmin.audit import open_audit  # noqa: E402
from sysadmin.config import settings_from  # noqa: E402
from sysadmin.runner import Runner, load_prelude  # noqa: E402
from sysadmin.service import Service  # noqa: E402
from sysadmin.transport import PsrpTransport  # noqa: E402


def env_settings():
    raw = {
        "host": os.environ["SYSADMIN_HOST"],
        "username": os.environ["SYSADMIN_USER"],
        "use_https": os.environ.get("SYSADMIN_HTTPS", "true"),
        "verify_tls": os.environ.get("SYSADMIN_VERIFY_TLS", "true"),
        "port": os.environ.get("SYSADMIN_PORT"),
        "mode": "strict",
    }
    return settings_from(raw, os.environ["SYSADMIN_WINRM_PASSWORD"])


def main(argv: list[str]) -> int:
    flags = [a for a in argv if a.startswith("--")]
    positional = [a for a in argv if not a.startswith("--")]
    if not positional:
        print(__doc__)
        return 2
    name = positional[0]
    args = json.loads(positional[1]) if len(positional) > 1 else {}
    settings = env_settings()
    service = Service(settings, Runner(PsrpTransport(settings, load_prelude())), open_audit())
    if "--preview" in flags:
        result = service.preview(name, args)
    else:
        result = service.call(name, args, actor="command", approved="--approve" in flags)
    print(json.dumps(result, indent=2, default=str))
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
```

- [ ] **Step 2: Run against the DC**

Run (with env vars exported as in the docstring):
```bash
.venv/bin/python scripts/smoke.py ad_connection_test
.venv/bin/python scripts/smoke.py ad_dc_list
.venv/bin/python scripts/smoke.py ad_domain_overview
.venv/bin/python scripts/smoke.py ad_dc_health
.venv/bin/python scripts/smoke.py ad_search '{"query": "admin", "kind": "user"}'
```
Expected: each prints `"ok": true`. `ad_connection_test` shows `"is_domain_controller": true` and an empty `warnings` list. If a script fails, the error JSON names the PowerShell message; fix the script, re-run `.venv/bin/pytest tests/test_scripts_contract.py`, and repeat.

- [ ] **Step 3: Install into Hermes and call through the agent**

Run:
```bash
ln -sfn "$(git rev-parse --show-toplevel)" ~/.hermes/plugins/hermes-sysadmin
hermes plugins enable hermes-sysadmin
hermes plugins list | grep hermes-sysadmin
```
Expected: `hermes-sysadmin` listed as enabled. Then in Hermes Desktop: Settings → Plugins → hermes-sysadmin, fill host/username/password, restart the gateway, and ask the agent "Give me an overview of the domain." Expected: the agent calls `ad_domain_overview` and reports real counts.

- [ ] **Step 4: Commit**

```bash
git add scripts/smoke.py
git commit -m "chore: smoke CLI for live checks

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
