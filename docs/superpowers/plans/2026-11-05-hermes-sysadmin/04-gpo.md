# Phase 4 — Group Policy

> Part of the [Hermes Sysadmin plan](README.md). Requires Phase 2. Follows the surface pattern described at the top of Phase 2.

**Deliverable:** 16 GPO tools (toolset `ad_gpo`): visibility with health checks, parsed settings reports, remote RSoP, lifecycle actions, backups, and automatic safety backups before delete/restore. All GroupPolicy cmdlets run on the jump-host DC (`-Server` is pinned by the prelude).

| Op | Tier | Notes |
|---|---|---|
| `gpo_list` | R | links parsed from `gPLink`; post adds `health` per GPO + `summary` |
| `gpo_health` | R | same script as `gpo_list`; post keeps only GPOs with issues |
| `gpo_get` | R | links, security filtering, delegation |
| `gpo_report` | R | `format=summary` (parsed settings) or `html` |
| `gpo_rsop` | R | runs `gpresult /x` on the target computer |
| `gpo_backups` | R | backups under `%ProgramData%\HermesSysadmin\GpoBackups` on the DC |
| `gpo_create`, `gpo_backup`, `gpo_update_hosts` | W | |
| `gpo_link`, `gpo_unlink`, `gpo_set_link` | W→H | escalate when the target is the domain root, Domain Controllers OU or a site; preview |
| `gpo_set_status`, `gpo_set_security_filter` | W→H | escalate for Default Domain / Default DC Policy |
| `gpo_delete`, `gpo_restore` | H | preview; automatic backup first |

---

### Task 1: GPO ops (Python)

**Files:**
- Create: `sysadmin/ops/gpo.py`
- Modify: `sysadmin/ops/__init__.py`
- Test: `tests/test_ops_gpo.py`

**Interfaces:**
- Consumes: `Op`, `Param`, `register`.
- Produces: ops in the table; helpers `gpo_issues(gpo: Mapping) -> list[str]`, `is_wide_scope(dn: str) -> bool`, `is_default_policy(identity: str) -> bool`. GPO row shape used by the dashboard: `{id, name, status, owner, created, modified, description, wmi_filter, user_version:{ad,sysvol}, computer_version:{ad,sysvol}, links:[{target, enabled, enforced, order}], health:[str]}`.

- [ ] **Step 1: Write the failing test** — `tests/test_ops_gpo.py`

```python
import pytest

from sysadmin import ops  # noqa: F401
from sysadmin.config import Settings
from sysadmin.ops.gpo import gpo_issues, is_default_policy, is_wide_scope
from sysadmin.policy import decide
from sysadmin.registry import OPS

EXPECTED = {
    "gpo_list": ("R", False), "gpo_health": ("R", False), "gpo_get": ("R", False), "gpo_report": ("R", False),
    "gpo_rsop": ("R", False), "gpo_backups": ("R", False),
    "gpo_create": ("W", False), "gpo_backup": ("W", False), "gpo_update_hosts": ("W", False),
    "gpo_link": ("W", True), "gpo_unlink": ("W", True), "gpo_set_link": ("W", True),
    "gpo_set_status": ("W", False), "gpo_set_security_filter": ("W", False),
    "gpo_delete": ("H", True), "gpo_restore": ("H", True),
}

GOOD = {
    "status": "AllSettingsEnabled",
    "links": [{"target": "OU=Staff,DC=corp", "enabled": True, "enforced": False, "order": 1}],
    "user_version": {"ad": 3, "sysvol": 3},
    "computer_version": {"ad": 5, "sysvol": 5},
}


@pytest.mark.parametrize("name", sorted(EXPECTED))
def test_tiers(name):
    assert (OPS[name].tier, OPS[name].preview) == EXPECTED[name]
    assert OPS[name].toolset == "ad_gpo"


@pytest.mark.parametrize(
    "changes, issue",
    [
        ({"links": []}, "Unlinked"),
        ({"links": [{"target": "OU=X", "enabled": False}]}, "All links disabled"),
        ({"status": "AllSettingsDisabled"}, "All settings disabled"),
        ({"user_version": {"ad": 0, "sysvol": 0}, "computer_version": {"ad": 0, "sysvol": 0}}, "Empty (no settings)"),
        ({"computer_version": {"ad": 14, "sysvol": 12}}, "Version mismatch: computer AD 14 / SYSVOL 12"),
        ({"user_version": {"ad": 2, "sysvol": 1}}, "Version mismatch: user AD 2 / SYSVOL 1"),
    ],
)
def test_gpo_issues(changes, issue):
    assert issue in gpo_issues({**GOOD, **changes})


def test_healthy_gpo_has_no_issues():
    assert gpo_issues(GOOD) == []


def test_list_and_health_posts():
    data = {"items": [{**GOOD, "name": "A"}, {**GOOD, "name": "B", "links": []}]}
    listed = OPS["gpo_list"].post(data, {}, Settings())
    assert [g["health"] for g in listed["items"]] == [[], ["Unlinked"]]
    assert listed["summary"] == {"total": 2, "needs_attention": 1, "unlinked": 1}
    health = OPS["gpo_health"].post(data, {}, Settings())
    assert [g["name"] for g in health["items"]] == ["B"]
    assert OPS["gpo_health"].script == "gpo_list"


@pytest.mark.parametrize(
    "dn, wide",
    [
        ("DC=corp,DC=example,DC=local", True),
        ("OU=Domain Controllers,DC=corp,DC=local", True),
        ("CN=Default-First-Site-Name,CN=Sites,CN=Configuration,DC=corp,DC=local", True),
        ("OU=Finance,OU=Staff,DC=corp,DC=local", False),
    ],
)
def test_is_wide_scope(dn, wide):
    assert is_wide_scope(dn) is wide


def test_link_escalates_for_wide_scope_only():
    s = Settings()
    assert decide(OPS["gpo_link"], {"identity": "Lock", "target": "DC=corp,DC=local"}, s).tier == "H"
    assert decide(OPS["gpo_link"], {"identity": "Lock", "target": "OU=Finance,DC=corp,DC=local"}, s).tier == "W"
    assert decide(OPS["gpo_unlink"], {"identity": "Lock", "target": "OU=Domain Controllers,DC=corp,DC=local"}, s).tier == "H"


def test_default_policies_escalate_status_and_filter_changes():
    s = Settings()
    assert is_default_policy("{31B2F340-016D-11D2-945F-00C04FB984F9}")
    assert is_default_policy("Default Domain Controllers Policy")
    assert decide(OPS["gpo_set_status"], {"identity": "Default Domain Policy", "status": "AllSettingsDisabled"}, s).tier == "H"
    assert decide(OPS["gpo_set_security_filter"], {"identity": "Finance Maps", "add": ["Finance"]}, s).tier == "W"


def test_protected_gpo_names_block_changes():
    s = Settings(protected_objects=("Workstation Baseline",))
    assert decide(OPS["gpo_delete"], {"identity": "workstation baseline"}, s).tier == "P"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_ops_gpo.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'sysadmin.ops.gpo'`

- [ ] **Step 3: Implement** — `sysadmin/ops/gpo.py`

```python
"""Group Policy operations."""

from __future__ import annotations

from typing import Any, Mapping

from ..registry import Op, Param, register

TOOLSET = "ad_gpo"
GPO = Param("identity", "string", "GPO display name or GUID.", required=True)
TARGET = Param("target", "string", "DN of the OU, domain or site the link is on.", required=True)
_DEFAULT_POLICIES = {
    "default domain policy",
    "default domain controllers policy",
    "31b2f340-016d-11d2-945f-00c04fb984f9",
    "6ac1786c-016f-11d2-945f-00c04fb984f9",
}


def is_wide_scope(dn: str) -> bool:
    text = dn.strip().lower()
    return text.startswith("dc=") or text.startswith("ou=domain controllers,") or ",cn=sites," in text


def is_default_policy(identity: str) -> bool:
    return identity.strip().strip("{}").lower() in _DEFAULT_POLICIES


def gpo_issues(gpo: Mapping[str, Any]) -> list[str]:
    issues: list[str] = []
    links = gpo.get("links") or []
    if not links:
        issues.append("Unlinked")
    elif all(not link.get("enabled") for link in links):
        issues.append("All links disabled")
    if gpo.get("status") == "AllSettingsDisabled":
        issues.append("All settings disabled")
    user = gpo.get("user_version") or {}
    computer = gpo.get("computer_version") or {}
    if user.get("ad") == 0 and computer.get("ad") == 0:
        issues.append("Empty (no settings)")
    for scope, version in (("computer", computer), ("user", user)):
        if version.get("ad") is not None and version.get("ad") != version.get("sysvol"):
            issues.append(f"Version mismatch: {scope} AD {version.get('ad')} / SYSVOL {version.get('sysvol')}")
    return issues


def _post_list(data: Any, args: Mapping[str, Any], settings: Any) -> Any:
    items = [{**g, "health": gpo_issues(g)} for g in (data or {}).get("items") or []]
    return {
        "items": items,
        "summary": {
            "total": len(items),
            "needs_attention": sum(1 for g in items if g["health"]),
            "unlinked": sum(1 for g in items if "Unlinked" in g["health"]),
        },
    }


def _post_health(data: Any, args: Mapping[str, Any], settings: Any) -> Any:
    listed = _post_list(data, args, settings)
    return {"items": [g for g in listed["items"] if g["health"]], "summary": listed["summary"]}


def _wide(args: Mapping[str, Any], settings: Any, facts: Any) -> bool:
    return is_wide_scope(str(args.get("target") or ""))


def _default(args: Mapping[str, Any], settings: Any, facts: Any) -> bool:
    return is_default_policy(str(args.get("identity") or ""))


def _link_target(a: Mapping[str, Any]) -> str:
    return f"{a.get('identity', '')} @ {a.get('target', '')}"


register(Op(
    name="gpo_list", toolset=TOOLSET, tier="R", script="gpo_list",
    description="List every GPO with status, versions, WMI filter, where it is linked (enabled/enforced/order) and health issues.",
    post=_post_list, cache_ttl=60,
))

register(Op(
    name="gpo_health", toolset=TOOLSET, tier="R", script="gpo_list",
    description="GPOs that need attention: unlinked, all links disabled, all settings disabled, empty, or AD/SYSVOL version mismatch.",
    post=_post_health, cache_ttl=60,
))

register(Op(
    name="gpo_get", toolset=TOOLSET, tier="R", script="gpo_get",
    description="One GPO: status, versions, links, security filtering (who it applies to) and delegation.",
    params=(GPO,),
))

register(Op(
    name="gpo_report", toolset=TOOLSET, tier="R", script="gpo_report",
    description="Settings report for a GPO: 'summary' lists configured settings per extension; 'html' returns the full GPMC HTML report.",
    params=(GPO, Param("format", "string", "Report format.", enum=("summary", "html"), default="summary")),
))

register(Op(
    name="gpo_rsop", toolset=TOOLSET, tier="R", script="gpo_rsop",
    description="Resultant Set of Policy on a computer (optionally for a user who has logged on there): which GPOs applied or were filtered out.",
    params=(
        Param("computer", "string", "Computer DNS name.", required=True),
        Param("user", "string", "DOMAIN\\user to include user-side results for."),
    ),
))

register(Op(
    name="gpo_backups", toolset=TOOLSET, tier="R", script="gpo_backups",
    description="List GPO backups taken by this plugin (optionally for one GPO), newest first.",
    params=(Param("identity", "string", "GPO display name or GUID."),),
))

register(Op(
    name="gpo_create", toolset=TOOLSET, tier="W", script="gpo_create",
    description="Create a new, unlinked GPO.",
    params=(Param("name", "string", "Display name.", required=True), Param("comment", "string", "Description.")),
    identities=("name",),
))

register(Op(
    name="gpo_backup", toolset=TOOLSET, tier="W", script="gpo_backup",
    description="Back up a GPO on the domain controller.",
    params=(GPO, Param("comment", "string", "Backup comment.", default="hermes-sysadmin backup")),
))

register(Op(
    name="gpo_update_hosts", toolset=TOOLSET, tier="W", script="gpo_update_hosts",
    description="Run gpupdate on computers (by name and/or every computer in an OU), with per-host results.",
    params=(
        Param("computers", "array", "Computer DNS names."),
        Param("ou", "string", "DN of an OU whose computers should refresh policy."),
        Param("force", "boolean", "Use /force.", default=True),
    ),
    target=lambda a: ", ".join(a.get("computers") or []) or a.get("ou", ""),
))

register(Op(
    name="gpo_link", toolset=TOOLSET, tier="W", script="gpo_link",
    description="Link a GPO to an OU, the domain or a site. Linking at the domain root, Domain Controllers or a site is high-risk.",
    params=(
        GPO, TARGET,
        Param("enforced", "boolean", "Enforce the link.", default=False),
        Param("enabled", "boolean", "Enable the link.", default=True),
    ),
    target=_link_target, identities=("identity",), escalate=_wide, preview=True,
))

register(Op(
    name="gpo_unlink", toolset=TOOLSET, tier="W", script="gpo_unlink",
    description="Remove a GPO link from an OU, the domain or a site.",
    params=(GPO, TARGET),
    target=_link_target, identities=("identity",), escalate=_wide, preview=True,
))

register(Op(
    name="gpo_set_link", toolset=TOOLSET, tier="W", script="gpo_set_link",
    description="Change an existing link: enforce/unenforce and/or enable/disable it.",
    params=(
        GPO, TARGET,
        Param("enforced", "boolean", "Enforced state."),
        Param("enabled", "boolean", "Enabled state."),
    ),
    target=_link_target, identities=("identity",), escalate=_wide, preview=True,
))

register(Op(
    name="gpo_set_status", toolset=TOOLSET, tier="W", script="gpo_set_status",
    description="Enable or disable a GPO's user and/or computer settings.",
    params=(
        GPO,
        Param("status", "string", "New status.", required=True,
              enum=("AllSettingsEnabled", "AllSettingsDisabled", "UserSettingsDisabled", "ComputerSettingsDisabled")),
    ),
    identities=("identity",), escalate=_default,
))

register(Op(
    name="gpo_set_security_filter", toolset=TOOLSET, tier="W", script="gpo_set_security_filter",
    description=(
        "Change who a GPO applies to: grant Apply to principals in 'add', remove it for principals in 'remove'. "
        "Removing Authenticated Users keeps its Read permission so the GPO still processes (MS16-072)."
    ),
    params=(GPO, Param("add", "array", "Groups/users/computers to grant Apply."), Param("remove", "array", "Principals to remove Apply from.")),
    identities=("identity",), escalate=_default,
))

register(Op(
    name="gpo_delete", toolset=TOOLSET, tier="H", script="gpo_delete",
    description="Delete a GPO and its links. A backup is taken automatically first.",
    params=(GPO,), identities=("identity",), preview=True,
))

register(Op(
    name="gpo_restore", toolset=TOOLSET, tier="H", script="gpo_restore",
    description="Restore a GPO's settings from a backup (see gpo_backups). The current state is backed up first; links are unchanged.",
    params=(GPO, Param("backup_id", "string", "Backup ID from gpo_backups.", required=True)),
    identities=("identity",), preview=True,
))
```

`sysadmin/ops/__init__.py`:
```python
"""Importing this package registers every operation in sysadmin.registry.OPS."""

from . import domain, gpo, users  # noqa: F401
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.venv/bin/pytest tests/test_ops_gpo.py`
Expected: `33 passed`

- [ ] **Step 5: Commit**

```bash
git add sysadmin/ops/gpo.py sysadmin/ops/__init__.py tests/test_ops_gpo.py
git commit -m "feat: GPO operations

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: GPO scripts

**Files:**
- Create (15): `sysadmin/scripts/gpo_list.ps1`, `gpo_get.ps1`, `gpo_report.ps1`, `gpo_rsop.ps1`, `gpo_backups.ps1`, `gpo_create.ps1`, `gpo_backup.ps1`, `gpo_update_hosts.ps1`, `gpo_link.ps1`, `gpo_unlink.ps1`, `gpo_set_link.ps1`, `gpo_set_status.ps1`, `gpo_set_security_filter.ps1`, `gpo_delete.ps1`, `gpo_restore.ps1`
- Modify: `plugin.yaml` (`provides_tools`)

**Interfaces:**
- Consumes: prelude helpers incl. `Get-HermesGpo`, `Get-XmlText`, `ConvertTo-LdapValue`, `Get-HermesFanout`.
- Produces: GPO row shape above; backup rows `{backup_id, gpo_id, gpo, time, comment}`; report `{id, name, sections:[{scope, extension, settings:[{name, state, category, value}]}]}` or `{id, name, html}`.

- [ ] **Step 1: Write the scripts**

`gpo_list.ps1`:
```powershell
param()
Invoke-Op {
    $links = @{}
    $containers = @(Get-ADObject -LDAPFilter '(gPLink=*)' -SearchBase (Get-ADDomain).DistinguishedName -Properties gPLink)
    $containers += @(Get-ADObject -LDAPFilter '(gPLink=*)' -SearchBase ('CN=Sites,' + (Get-ADRootDSE).configurationNamingContext) -Properties gPLink -ErrorAction SilentlyContinue)
    foreach ($c in $containers) {
        $entries = [regex]::Matches("$($c.gPLink)", '\[LDAP://[Cc][Nn]=(\{[0-9A-Fa-f-]+\})[^;]*;(\d)\]')
        $order = $entries.Count
        foreach ($m in $entries) {
            $guid = $m.Groups[1].Value.ToUpper()
            $flag = [int]$m.Groups[2].Value
            if (-not $links.ContainsKey($guid)) { $links[$guid] = @() }
            $links[$guid] += @{ target = $c.DistinguishedName; enabled = (($flag -band 1) -eq 0); enforced = (($flag -band 2) -ne 0); order = $order }
            $order--
        }
    }
    $items = @(Get-GPO -All | Sort-Object DisplayName | ForEach-Object {
        $guid = '{' + $_.Id.ToString().ToUpper() + '}'
        @{
            id               = $_.Id.ToString()
            name             = $_.DisplayName
            status           = "$($_.GpoStatus)"
            owner            = $_.Owner
            created          = (Iso $_.CreationTime)
            modified         = (Iso $_.ModificationTime)
            description      = "$($_.Description)"
            wmi_filter       = $(if ($_.WmiFilter) { $_.WmiFilter.Name } else { $null })
            user_version     = @{ ad = $_.User.DSVersion; sysvol = $_.User.SysvolVersion }
            computer_version = @{ ad = $_.Computer.DSVersion; sysvol = $_.Computer.SysvolVersion }
            links            = @($(if ($links.ContainsKey($guid)) { $links[$guid] } else { @() }))
        }
    })
    @{ items = $items }
}
```

`gpo_get.ps1`:
```powershell
param([Parameter(Mandatory)][string]$Identity)
Invoke-Op {
    $gpo = Get-HermesGpo $Identity
    $guid = '{' + $gpo.Id.ToString().ToUpper() + '}'
    $links = @()
    $containers = @(Get-ADObject -LDAPFilter "(gPLink=*$guid*)" -Properties gPLink)
    $containers += @(Get-ADObject -LDAPFilter "(gPLink=*$guid*)" -SearchBase ('CN=Sites,' + (Get-ADRootDSE).configurationNamingContext) -Properties gPLink -ErrorAction SilentlyContinue)
    foreach ($c in $containers) {
        foreach ($m in [regex]::Matches("$($c.gPLink)", '\[LDAP://[Cc][Nn]=(\{[0-9A-Fa-f-]+\})[^;]*;(\d)\]')) {
            if ($m.Groups[1].Value.ToUpper() -ne $guid) { continue }
            $flag = [int]$m.Groups[2].Value
            $links += @{ target = $c.DistinguishedName; enabled = (($flag -band 1) -eq 0); enforced = (($flag -band 2) -ne 0) }
        }
    }
    $perms = @(Get-GPPermission -Guid $gpo.Id -All)
    @{
        id                 = $gpo.Id.ToString()
        name               = $gpo.DisplayName
        status             = "$($gpo.GpoStatus)"
        owner              = $gpo.Owner
        description        = "$($gpo.Description)"
        created            = (Iso $gpo.CreationTime)
        modified           = (Iso $gpo.ModificationTime)
        wmi_filter         = $(if ($gpo.WmiFilter) { $gpo.WmiFilter.Name } else { $null })
        user_version       = @{ ad = $gpo.User.DSVersion; sysvol = $gpo.User.SysvolVersion }
        computer_version   = @{ ad = $gpo.Computer.DSVersion; sysvol = $gpo.Computer.SysvolVersion }
        links              = $links
        security_filtering = @($perms | Where-Object { "$($_.Permission)" -eq 'GpoApply' } | ForEach-Object { "$($_.Trustee.Name)" })
        delegation         = @($perms | Where-Object { "$($_.Permission)" -ne 'GpoApply' } | ForEach-Object { @{ trustee = "$($_.Trustee.Name)"; permission = "$($_.Permission)" } })
    }
}
```

`gpo_report.ps1`:
```powershell
param(
    [Parameter(Mandatory)][string]$Identity,
    [ValidateSet('summary', 'html')][string]$Format = 'summary'
)
Invoke-Op {
    $gpo = Get-HermesGpo $Identity
    if ($Format -eq 'html') {
        return @{ id = $gpo.Id.ToString(); name = $gpo.DisplayName; html = (Get-GPOReport -Guid $gpo.Id -ReportType Html) }
    }
    [xml]$x = Get-GPOReport -Guid $gpo.Id -ReportType Xml
    $sections = @()
    foreach ($scope in @('Computer', 'User')) {
        $node = $x.GPO.$scope
        if (-not $node) { continue }
        foreach ($ext in @($node.ExtensionData)) {
            if (-not $ext -or -not $ext.Extension) { continue }
            $settings = @()
            foreach ($p in @($ext.Extension.SelectNodes(".//*[local-name()='Policy']"))) {
                $value = "$($p.Numeric.Value)$($p.EditText.Value)$($p.DropDownList.Value.Name)$($p.CheckBox.State)"
                $settings += @{ name = "$($p.Name)"; state = "$($p.State)"; category = "$($p.Category)"; value = $value }
            }
            foreach ($r in @($ext.Extension.SelectNodes(".//*[local-name()='RegistrySetting']"))) {
                $settings += @{ name = "$($r.KeyPath)\$($r.Value.Name)"; state = 'Set'; category = 'Registry'; value = "$($r.Value.Number)$($r.Value.String)" }
            }
            foreach ($s in @($ext.Extension.SelectNodes(".//*[local-name()='SecurityOptions' or local-name()='Account' or local-name()='Audit' or local-name()='UserRightsAssignment']"))) {
                $name = "$($s.KeyName)$($s.Name)$($s.SystemAccessPolicyName)"
                $value = "$($s.SettingNumber)$($s.SettingString)$($s.SettingBoolean)$($s.Display.DisplayString)"
                $settings += @{ name = $name; state = 'Set'; category = "$($s.LocalName)"; value = $value }
            }
            $sections += @{ scope = $scope; extension = "$($ext.Name)"; settings = @($settings | Select-Object -First 200) }
        }
    }
    @{ id = $gpo.Id.ToString(); name = $gpo.DisplayName; sections = $sections }
}
```

`gpo_rsop.ps1`:
```powershell
param(
    [Parameter(Mandatory)][string]$Computer,
    [string]$User
)
Invoke-Op {
    $remote = Get-HermesFanout -Computers @($Computer) -ArgumentList @($User) -Script {
        param($U)
        $path = Join-Path $env:TEMP ('hermes-rsop-' + [guid]::NewGuid().ToString() + '.xml')
        $gpArgs = @('/x', $path, '/f')
        if ($U) { $gpArgs += @('/user', $U) } else { $gpArgs += @('/scope', 'computer') }
        $null = & gpresult.exe @gpArgs 2>&1
        if (-not (Test-Path $path)) { throw 'gpresult produced no report (for a user, they must have logged on to this computer).' }
        [xml]$x = Get-Content -Path $path -Raw
        Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
        $read = {
            param($node)
            @(foreach ($g in @($node.GPO)) {
                if (-not $g) { continue }
                [pscustomobject]@{
                    name           = "$($g.Name)"
                    applied        = ("$($g.Enabled)" -eq 'true' -and "$($g.IsValid)" -eq 'true' -and "$($g.FilterAllowed)" -eq 'true' -and "$($g.AccessDenied)" -eq 'false')
                    filter_allowed = ("$($g.FilterAllowed)" -eq 'true')
                    access_denied  = ("$($g.AccessDenied)" -eq 'true')
                    link           = "$($g.Link.SOMPath)"
                }
            })
        }
        [pscustomobject]@{
            computer_gpos      = @(& $read $x.Rsop.ComputerResults)
            user_gpos          = @(& $read $x.Rsop.UserResults)
            computer_read_time = "$($x.Rsop.ComputerResults.ReadTime)"
            user_read_time     = "$($x.Rsop.UserResults.ReadTime)"
        }
    }
    if ($remote.errors.Count -gt 0) { throw "$($remote.errors[0].host): $($remote.errors[0].message)" }
    $r = $remote.results[0]
    @{
        computer           = $Computer
        user               = $User
        computer_gpos      = @($r.computer_gpos)
        user_gpos          = @($r.user_gpos)
        computer_read_time = $r.computer_read_time
        user_read_time     = $r.user_read_time
    }
}
```

`gpo_backups.ps1`:
```powershell
param([string]$Identity)
Invoke-Op {
    $root = Join-Path $env:ProgramData 'HermesSysadmin\GpoBackups'
    if (-not (Test-Path $root)) { return @{ items = @(); path = $root } }
    $filterId = $null
    if ($Identity) { $filterId = (Get-HermesGpo $Identity).Id.ToString() }
    $items = @(Get-ChildItem -Path $root -Directory | ForEach-Object {
        $info = Join-Path $_.FullName 'bkupInfo.xml'
        if (-not (Test-Path $info)) { return }
        [xml]$x = Get-Content -Path $info -Raw
        $gid = (Get-XmlText $x.BackupInst.GPOGuid).Trim('{}')
        if ($filterId -and $gid -ne $filterId) { return }
        @{
            backup_id = (Get-XmlText $x.BackupInst.ID).Trim('{}')
            gpo_id    = $gid
            gpo       = (Get-XmlText $x.BackupInst.GPODisplayName)
            time      = (Iso (Get-XmlText $x.BackupInst.BackupTime))
            comment   = (Get-XmlText $x.BackupInst.Comment)
        }
    } | Sort-Object { $_.time } -Descending)
    @{ items = $items; path = $root }
}
```

`gpo_create.ps1`:
```powershell
param(
    [Parameter(Mandatory)][string]$Name,
    [string]$Comment
)
Invoke-Op {
    $splat = @{ Name = $Name }
    if ($Comment) { $splat.Comment = $Comment }
    $gpo = New-GPO @splat
    @{ id = $gpo.Id.ToString(); name = $gpo.DisplayName; status = "$($gpo.GpoStatus)" }
}
```

`gpo_backup.ps1`:
```powershell
param(
    [Parameter(Mandatory)][string]$Identity,
    [string]$Comment = 'hermes-sysadmin backup'
)
Invoke-Op {
    $gpo = Get-HermesGpo $Identity
    $root = Join-Path $env:ProgramData 'HermesSysadmin\GpoBackups'
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $b = Backup-GPO -Guid $gpo.Id -Path $root -Comment $Comment
    @{ gpo = $gpo.DisplayName; gpo_id = $gpo.Id.ToString(); backup_id = $b.Id.ToString(); time = (Iso $b.Timestamp); comment = $Comment }
}
```

`gpo_update_hosts.ps1`:
```powershell
param(
    [string[]]$Computers = @(),
    [string]$Ou,
    [bool]$Force = $true
)
Invoke-Op {
    $targets = @($Computers)
    if ($Ou) { $targets += @(Get-ADComputer -Filter * -SearchBase $Ou -Properties DNSHostName | ForEach-Object { $_.DNSHostName } | Where-Object { $_ }) }
    $targets = @($targets | Sort-Object -Unique)
    Assert-Hermes ($targets.Count -gt 0) 'Give computers or an OU that contains computers.'
    $remote = Get-HermesFanout -Computers $targets -ArgumentList @($Force) -Script {
        param($F)
        $gpArgs = @('/target:computer')
        if ($F) { $gpArgs += '/force' }
        $out = (& gpupdate.exe @gpArgs 2>&1 | Out-String).Trim()
        [pscustomobject]@{
            ok        = ($LASTEXITCODE -eq 0)
            exit_code = $LASTEXITCODE
            output    = $(if ($out.Length -gt 400) { $out.Substring($out.Length - 400) } else { $out })
        }
    }
    @{ targets = $targets.Count; results = $remote.results; errors = $remote.errors }
}
```

`gpo_link.ps1`:
```powershell
param(
    [Parameter(Mandatory)][string]$Identity,
    [Parameter(Mandatory)][string]$Target,
    [bool]$Enforced = $false,
    [bool]$Enabled = $true,
    [switch]$Preview
)
Invoke-Op {
    $gpo = Get-HermesGpo $Identity
    $enabledArg = if ($Enabled) { 'Yes' } else { 'No' }
    $enforcedArg = if ($Enforced) { 'Yes' } else { 'No' }
    if ($Preview) {
        $inherit = Get-GPInheritance -Target $Target
        return @{
            summary = "Link '$($gpo.DisplayName)' to $Target"
            changes = @("New-GPLink -Guid $($gpo.Id) -Target '$Target' -LinkEnabled $enabledArg -Enforced $enforcedArg")
            current = @{
                linked_here = @($inherit.GpoLinks | ForEach-Object { $_.DisplayName })
                inherited   = @($inherit.InheritedGpoLinks | Select-Object -First 20 | ForEach-Object { $_.DisplayName })
            }
        }
    }
    $link = New-GPLink -Guid $gpo.Id -Target $Target -LinkEnabled $enabledArg -Enforced $enforcedArg
    @{ gpo = $gpo.DisplayName; target = $Target; enabled = $Enabled; enforced = $Enforced; order = $link.Order }
}
```

`gpo_unlink.ps1`:
```powershell
param(
    [Parameter(Mandatory)][string]$Identity,
    [Parameter(Mandatory)][string]$Target,
    [switch]$Preview
)
Invoke-Op {
    $gpo = Get-HermesGpo $Identity
    if ($Preview) {
        $inherit = Get-GPInheritance -Target $Target
        return @{
            summary = "Unlink '$($gpo.DisplayName)' from $Target"
            changes = @("Remove-GPLink -Guid $($gpo.Id) -Target '$Target'")
            current = @{ linked_here = @($inherit.GpoLinks | ForEach-Object { $_.DisplayName }) }
        }
    }
    Remove-GPLink -Guid $gpo.Id -Target $Target | Out-Null
    @{ gpo = $gpo.DisplayName; target = $Target; unlinked = $true }
}
```

`gpo_set_link.ps1`:
```powershell
param(
    [Parameter(Mandatory)][string]$Identity,
    [Parameter(Mandatory)][string]$Target,
    [Nullable[bool]]$Enforced = $null,
    [Nullable[bool]]$Enabled = $null,
    [switch]$Preview
)
Invoke-Op {
    Assert-Hermes ($null -ne $Enforced -or $null -ne $Enabled) 'Give enforced and/or enabled.'
    $gpo = Get-HermesGpo $Identity
    $splat = @{ Guid = $gpo.Id; Target = $Target }
    if ($null -ne $Enforced) { $splat.Enforced = $(if ($Enforced) { 'Yes' } else { 'No' }) }
    if ($null -ne $Enabled) { $splat.LinkEnabled = $(if ($Enabled) { 'Yes' } else { 'No' }) }
    if ($Preview) {
        $parts = @($splat.Keys | Where-Object { $_ -notin 'Guid', 'Target' } | ForEach-Object { "-$_ $($splat[$_])" })
        return @{ summary = "Change link of '$($gpo.DisplayName)' on $Target"; changes = @("Set-GPLink -Guid $($gpo.Id) -Target '$Target' $($parts -join ' ')") }
    }
    $link = Set-GPLink @splat
    @{ gpo = $gpo.DisplayName; target = $Target; enabled = "$($link.Enabled)"; enforced = "$($link.Enforced)"; order = $link.Order }
}
```

`gpo_set_status.ps1`:
```powershell
param(
    [Parameter(Mandatory)][string]$Identity,
    [Parameter(Mandatory)][ValidateSet('AllSettingsEnabled', 'AllSettingsDisabled', 'UserSettingsDisabled', 'ComputerSettingsDisabled')][string]$Status
)
Invoke-Op {
    $gpo = Get-HermesGpo $Identity
    $before = "$($gpo.GpoStatus)"
    $gpo.GpoStatus = $Status
    @{ gpo = $gpo.DisplayName; from = $before; to = $Status }
}
```

`gpo_set_security_filter.ps1`:
```powershell
param(
    [Parameter(Mandatory)][string]$Identity,
    [string[]]$Add = @(),
    [string[]]$Remove = @()
)
Invoke-Op {
    Assert-Hermes (($Add.Count + $Remove.Count) -gt 0) 'Give principals to add and/or remove.'
    $gpo = Get-HermesGpo $Identity
    $typeOf = {
        param($n)
        $o = Get-ADObject -LDAPFilter "(sAMAccountName=$(ConvertTo-LdapValue $n))" | Select-Object -First 1
        if (-not $o) { return 'Group' }
        switch ($o.ObjectClass) { 'computer' { 'Computer' } 'user' { 'User' } default { 'Group' } }
    }
    foreach ($n in $Add) {
        Set-GPPermission -Guid $gpo.Id -TargetName $n -TargetType (& $typeOf $n) -PermissionLevel GpoApply | Out-Null
    }
    foreach ($n in $Remove) {
        if ($n -eq 'Authenticated Users') {
            Set-GPPermission -Guid $gpo.Id -TargetName $n -TargetType Group -PermissionLevel GpoRead -Replace | Out-Null
        } else {
            Set-GPPermission -Guid $gpo.Id -TargetName $n -TargetType (& $typeOf $n) -PermissionLevel None -Replace | Out-Null
        }
    }
    $apply = @(Get-GPPermission -Guid $gpo.Id -All | Where-Object { "$($_.Permission)" -eq 'GpoApply' } | ForEach-Object { "$($_.Trustee.Name)" })
    @{ gpo = $gpo.DisplayName; added = @($Add); removed = @($Remove); security_filtering = $apply }
}
```

`gpo_delete.ps1`:
```powershell
param(
    [Parameter(Mandatory)][string]$Identity,
    [switch]$Preview
)
Invoke-Op {
    $gpo = Get-HermesGpo $Identity
    $guid = '{' + $gpo.Id.ToString().ToUpper() + '}'
    $linked = @(Get-ADObject -LDAPFilter "(gPLink=*$guid*)" | ForEach-Object { $_.DistinguishedName })
    if ($Preview) {
        return @{
            summary = "Delete GPO '$($gpo.DisplayName)'"
            changes = @('Backup-GPO (automatic, before delete)', "Remove-GPO -Guid $($gpo.Id) (removes $($linked.Count) link(s))")
            current = @{ links = $linked; status = "$($gpo.GpoStatus)"; modified = (Iso $gpo.ModificationTime) }
        }
    }
    $root = Join-Path $env:ProgramData 'HermesSysadmin\GpoBackups'
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $b = Backup-GPO -Guid $gpo.Id -Path $root -Comment 'hermes-sysadmin: automatic backup before delete'
    Remove-GPO -Guid $gpo.Id -Confirm:$false
    @{ deleted = $gpo.DisplayName; backup_id = $b.Id.ToString(); links_removed = $linked }
}
```

`gpo_restore.ps1`:
```powershell
param(
    [Parameter(Mandatory)][string]$Identity,
    [Parameter(Mandatory)][string]$BackupId,
    [switch]$Preview
)
Invoke-Op {
    $gpo = Get-HermesGpo $Identity
    $root = Join-Path $env:ProgramData 'HermesSysadmin\GpoBackups'
    $id = $BackupId.Trim('{}')
    $info = Join-Path (Join-Path $root ('{' + $id + '}')) 'bkupInfo.xml'
    Assert-Hermes (Test-Path $info) "No backup $id under $root."
    [xml]$x = Get-Content -Path $info -Raw
    Assert-Hermes ((Get-XmlText $x.BackupInst.GPOGuid).Trim('{}') -eq $gpo.Id.ToString()) 'That backup belongs to a different GPO.'
    $taken = Iso (Get-XmlText $x.BackupInst.BackupTime)
    if ($Preview) {
        return @{
            summary = "Restore '$($gpo.DisplayName)' from backup taken $taken"
            changes = @("Backup-GPO (current state) -> $root", "Restore-GPO -Guid $($gpo.Id) -BackupId $id", 'Links are not changed by a restore.')
            current = @{ modified = (Iso $gpo.ModificationTime); backup_comment = (Get-XmlText $x.BackupInst.Comment) }
        }
    }
    $safety = Backup-GPO -Guid $gpo.Id -Path $root -Comment 'hermes-sysadmin: automatic backup before restore'
    Restore-GPO -Guid $gpo.Id -BackupId $id -Path $root | Out-Null
    @{ gpo = $gpo.DisplayName; restored_from = $id; backup_time = $taken; safety_backup_id = $safety.Id.ToString() }
}
```

- [ ] **Step 2: Update `plugin.yaml` `provides_tools`** — append (keep the list sorted):

```yaml
  - gpo_backup
  - gpo_backups
  - gpo_create
  - gpo_delete
  - gpo_get
  - gpo_health
  - gpo_link
  - gpo_list
  - gpo_report
  - gpo_restore
  - gpo_rsop
  - gpo_set_link
  - gpo_set_security_filter
  - gpo_set_status
  - gpo_unlink
  - gpo_update_hosts
```

- [ ] **Step 3: Run the suite**

Run: `.venv/bin/pytest`
Expected: all pass (contract test now covers 15 new scripts; `gpo_health` reuses `gpo_list.ps1`).

- [ ] **Step 4: Live smoke** (test OU from Phase 3)

```bash
OU='OU=HermesTest,DC=corp,DC=example,DC=local'
.venv/bin/python scripts/smoke.py gpo_list
.venv/bin/python scripts/smoke.py gpo_create '{"name": "zz-hermes-test-gpo", "comment": "plan smoke test"}' --approve
.venv/bin/python scripts/smoke.py gpo_backup '{"identity": "zz-hermes-test-gpo"}' --approve
.venv/bin/python scripts/smoke.py gpo_link "{\"identity\": \"zz-hermes-test-gpo\", \"target\": \"$OU\"}" --preview
.venv/bin/python scripts/smoke.py gpo_link "{\"identity\": \"zz-hermes-test-gpo\", \"target\": \"$OU\"}" --approve
.venv/bin/python scripts/smoke.py gpo_get '{"identity": "zz-hermes-test-gpo"}'
.venv/bin/python scripts/smoke.py gpo_report '{"identity": "Default Domain Policy"}'
.venv/bin/python scripts/smoke.py gpo_backups '{"identity": "zz-hermes-test-gpo"}'
.venv/bin/python scripts/smoke.py gpo_rsop '{"computer": "<a member server FQDN>"}'
.venv/bin/python scripts/smoke.py gpo_update_hosts '{"computers": ["<a member server FQDN>"]}' --approve
.venv/bin/python scripts/smoke.py gpo_delete '{"identity": "zz-hermes-test-gpo"}' --preview
.venv/bin/python scripts/smoke.py gpo_delete '{"identity": "zz-hermes-test-gpo"}' --approve
```
Replace `<a member server FQDN>` with a real server name before running. Expected: all `"ok": true`; `gpo_get` shows the link on the test OU; `gpo_report` lists Default Domain Policy password/lockout settings in `sections`; `gpo_delete` returns a `backup_id` that appears in `gpo_backups`.

- [ ] **Step 5: Commit**

```bash
git add sysadmin/scripts plugin.yaml
git commit -m "feat: GPO PowerShell scripts

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
