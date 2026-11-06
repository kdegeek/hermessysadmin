# Phase 3 — Users, groups, lockouts, Recycle Bin

> Part of the [Hermes Sysadmin plan](README.md). Requires Phase 2. Follows the surface pattern described at the top of Phase 2.

**Deliverable:** 17 user/group tools (toolset `ad_users`) with privileged-group escalation, protected-object checks, template copying that never copies privileged groups, one-time generated passwords, and lockout-source analysis.

| Op | Tier | Notes |
|---|---|---|
| `ad_user_get` | R | post adds `privileged` |
| `ad_user_list` | R | filters; post handles `privileged` filter + `limit` |
| `ad_lockout_source` | R | event 4740 on PDC + badPwdCount per DC; post adds `sources`, `likely_source` |
| `ad_group_get`, `ad_group_list` | R | post adds `privileged` |
| `ad_recycle_bin_list` | R | |
| `ad_user_create` | W | generated password returned once; template copy skips privileged groups (`inject`) |
| `ad_user_update`, `ad_user_reset_password`, `ad_user_unlock`, `ad_user_enable`, `ad_user_disable`, `ad_user_move` | W | |
| `ad_group_add_member`, `ad_group_remove_member` | W→H | escalate on privileged group; preview |
| `ad_recycle_bin_restore` | W | |
| `ad_user_delete` | H | preview |

---

### Task 1: User and group ops (Python)

**Files:**
- Create: `sysadmin/ops/users.py`
- Modify: `sysadmin/ops/__init__.py`
- Test: `tests/test_ops_users.py`

**Interfaces:**
- Consumes: `Op`, `Param`, `register`, `is_privileged_group`, `PRIVILEGED_DEFAULT`.
- Produces: the ops in the table; helpers `privileged_group_names(settings) -> list[str]`, `with_privileged(obj, settings) -> dict`.

- [ ] **Step 1: Write the failing test** — `tests/test_ops_users.py`

```python
import pytest

from sysadmin import ops  # noqa: F401
from sysadmin.config import Settings
from sysadmin.ops.users import privileged_group_names
from sysadmin.policy import decide
from sysadmin.registry import OPS, coerce_args

EXPECTED = {
    "ad_user_get": ("R", False), "ad_user_list": ("R", False), "ad_lockout_source": ("R", False),
    "ad_group_get": ("R", False), "ad_group_list": ("R", False), "ad_recycle_bin_list": ("R", False),
    "ad_user_create": ("W", False), "ad_user_update": ("W", False), "ad_user_reset_password": ("W", False),
    "ad_user_unlock": ("W", False), "ad_user_enable": ("W", False), "ad_user_disable": ("W", False),
    "ad_user_move": ("W", False), "ad_group_add_member": ("W", True), "ad_group_remove_member": ("W", True),
    "ad_recycle_bin_restore": ("W", False), "ad_user_delete": ("H", True),
}


@pytest.mark.parametrize("name", sorted(EXPECTED))
def test_tier_preview_and_toolset(name):
    op = OPS[name]
    assert (op.tier, op.preview) == EXPECTED[name]
    assert op.toolset == "ad_users"


def test_group_change_escalates_only_for_privileged_groups():
    s = Settings()
    op = OPS["ad_group_add_member"]
    assert decide(op, {"group": "Domain Admins", "members": ["bob"]}, s).tier == "H"
    assert decide(op, {"group": "Finance-RW", "members": ["bob"]}, s).tier == "W"
    assert decide(OPS["ad_group_remove_member"], {"group": "Schema Admins", "members": ["bob"]}, s).tier == "H"


def test_protected_accounts_blocked_on_user_and_group_ops():
    s = Settings(protected_objects=("ceo",))
    assert decide(OPS["ad_user_reset_password"], {"identity": "Administrator"}, s).tier == "P"
    assert decide(OPS["ad_user_create"], {"sam": "krbtgt"}, s).tier == "P"
    assert decide(OPS["ad_group_add_member"], {"group": "Staff", "members": ["CEO"]}, s).tier == "P"
    assert decide(OPS["ad_user_disable"], {"identity": "amy"}, s).action == "approve"


def test_group_targets_are_readable():
    from sysadmin.registry import target_of

    assert target_of(OPS["ad_group_add_member"], {"group": "Admins", "members": ["a", "b"]}) == "Admins ← a, b"
    assert target_of(OPS["ad_group_remove_member"], {"group": "Admins", "members": ["a"]}) == "Admins → a"


def test_create_injects_privileged_groups_including_configured():
    names = privileged_group_names(Settings(privileged_groups=("Tier0",)))
    assert "domain admins" in names and "tier0" in names
    assert OPS["ad_user_create"].inject(Settings())["PrivilegedGroups"] == privileged_group_names(Settings())


def test_user_get_post_flags_privileged():
    post = OPS["ad_user_get"].post
    assert post({"sam": "a", "groups": ["Staff", "Domain Admins"]}, {}, Settings())["privileged"] is True
    assert post({"sam": "b", "groups": ["Staff"]}, {}, Settings())["privileged"] is False


def test_user_list_post_filters_privileged_and_limits():
    post = OPS["ad_user_list"].post
    data = {"items": [{"sam": "a", "groups": ["Domain Admins"]}, {"sam": "b", "groups": []}, {"sam": "c", "groups": ["Backup Operators"]}], "total": 3}
    out = post(data, {"privileged": True, "limit": 1}, Settings())
    assert [u["sam"] for u in out["items"]] == ["a"]
    assert out["total"] == 2
    out = post(data, {"privileged": False, "limit": 200}, Settings())
    assert out["total"] == 3 and [u["privileged"] for u in out["items"]] == [True, False, True]


def test_lockout_post_ranks_sources():
    post = OPS["ad_lockout_source"].post
    out = post({"events": [{"source": "SRV-APP02"}, {"source": "WS-1"}, {"source": "SRV-APP02"}, {"source": ""}]}, {}, Settings())
    assert out["sources"] == [{"source": "SRV-APP02", "count": 2}, {"source": "(unknown)", "count": 1}, {"source": "WS-1", "count": 1}]
    assert out["likely_source"] == "SRV-APP02"
    assert post({"events": []}, {}, Settings())["likely_source"] is None


def test_user_list_defaults():
    assert coerce_args(OPS["ad_user_list"], {}) == {
        "status": "any", "password": "any", "expiring_days": 7, "privileged": False, "limit": 200,
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_ops_users.py`
Expected: FAIL — `KeyError: 'ad_user_get'` (or ImportError for `sysadmin.ops.users`)

- [ ] **Step 3: Implement** — `sysadmin/ops/users.py`

```python
"""User, group, lockout and AD Recycle Bin operations."""

from __future__ import annotations

from typing import Any, Mapping

from ..policy import PRIVILEGED_DEFAULT, is_privileged_group, normalize_identity
from ..registry import Op, Param, register

TOOLSET = "ad_users"
IDENTITY = Param("identity", "string", "sAMAccountName, UPN or distinguished name of the user.", required=True)


def privileged_group_names(settings: Any) -> list[str]:
    names = list(PRIVILEGED_DEFAULT) + [normalize_identity(g) for g in settings.privileged_groups]
    return sorted(set(names))


def _privileged_change(args: Mapping[str, Any], settings: Any, facts: Any) -> bool:
    return is_privileged_group(str(args.get("group") or ""), settings)


def with_privileged(obj: Mapping[str, Any], settings: Any) -> dict[str, Any]:
    groups = obj.get("groups") or []
    name = obj.get("name") or ""
    flag = any(is_privileged_group(g, settings) for g in groups) or (
        "groups" not in obj and bool(name) and is_privileged_group(name, settings)
    )
    return {**obj, "privileged": flag}


def _post_user_get(data: Any, args: Mapping[str, Any], settings: Any) -> Any:
    return with_privileged(data or {}, settings)


def _post_user_list(data: Any, args: Mapping[str, Any], settings: Any) -> Any:
    data = data or {}
    items = [with_privileged(u, settings) for u in data.get("items") or []]
    limit = int(args.get("limit") or 200)
    if args.get("privileged"):
        items = [u for u in items if u["privileged"]]
        total = len(items)
    else:
        total = int(data.get("total", len(items)))
    return {"items": items[:limit], "total": total, "limit": limit}


def _post_groups(data: Any, args: Mapping[str, Any], settings: Any) -> Any:
    data = dict(data or {})
    data["items"] = [{**g, "privileged": is_privileged_group(g.get("name", ""), settings)} for g in data.get("items") or []]
    return data


def _post_group_get(data: Any, args: Mapping[str, Any], settings: Any) -> Any:
    data = dict(data or {})
    data["privileged"] = is_privileged_group(data.get("name", ""), settings)
    return data


def _post_lockout(data: Any, args: Mapping[str, Any], settings: Any) -> Any:
    data = dict(data or {})
    counts: dict[str, int] = {}
    for event in data.get("events") or []:
        source = str(event.get("source") or "").strip() or "(unknown)"
        counts[source] = counts.get(source, 0) + 1
    sources = sorted(({"source": s, "count": c} for s, c in counts.items()), key=lambda x: (-x["count"], x["source"]))
    data["sources"] = sources
    data["likely_source"] = sources[0]["source"] if sources else None
    return data


def _members_target(arrow: str):
    return lambda a: f"{a.get('group', '')} {arrow} {', '.join(a.get('members') or [])}"


# ---- reads ---------------------------------------------------------------

register(Op(
    name="ad_user_get", toolset=TOOLSET, tier="R", script="ad_user_get",
    description="Full detail for one user: status, lockout, password expiry, last logon, attributes and group memberships.",
    params=(IDENTITY,), post=_post_user_get,
))

register(Op(
    name="ad_user_list", toolset=TOOLSET, tier="R", script="ad_user_list",
    description=(
        "List users with filters: name query, OU, status (enabled/disabled/locked), password state "
        "(expired/expiring/never_expires), stale for N days, privileged only."
    ),
    params=(
        Param("query", "string", "Name fragment (ambiguous name resolution)."),
        Param("ou", "string", "Distinguished name of the OU to search.", ps="SearchBase"),
        Param("status", "string", "Account status filter.", enum=("any", "enabled", "disabled", "locked"), default="any"),
        Param("password", "string", "Password state filter.", enum=("any", "expired", "expiring", "never_expires"), default="any"),
        Param("stale_days", "integer", "Only users with no logon in this many days.", minimum=1),
        Param("expiring_days", "integer", "Window for 'expiring'.", default=7, minimum=1),
        Param("privileged", "boolean", "Only members of privileged groups.", default=False),
        Param("limit", "integer", "Maximum users returned.", default=200, minimum=1),
    ),
    post=_post_user_list,
))

register(Op(
    name="ad_lockout_source", toolset=TOOLSET, tier="R", script="ad_lockout_source",
    description=(
        "Find what is locking an account out: lockout events (4740) on the PDC emulator with the calling "
        "computer, and bad-password counts per domain controller."
    ),
    params=(IDENTITY, Param("hours", "integer", "How far back to look.", default=24, minimum=1)),
    post=_post_lockout,
))

register(Op(
    name="ad_group_get", toolset=TOOLSET, tier="R", script="ad_group_get",
    description="One group's scope, category, description, manager and members.",
    params=(
        Param("identity", "string", "Group name, sAMAccountName or DN.", required=True),
        Param("limit", "integer", "Maximum members returned.", default=500, minimum=1),
    ),
    post=_post_group_get,
))

register(Op(
    name="ad_group_list", toolset=TOOLSET, tier="R", script="ad_group_list",
    description="List groups (optionally matching a name) with scope, category and member count.",
    params=(Param("query", "string", "Name fragment."), Param("limit", "integer", "Maximum groups.", default=100, minimum=1)),
    post=_post_groups,
))

register(Op(
    name="ad_recycle_bin_list", toolset=TOOLSET, tier="R", script="ad_recycle_bin_list",
    description="List deleted objects in the AD Recycle Bin with their last known parent OU.",
    params=(
        Param("kind", "string", "Object class filter.", enum=("any", "user", "group", "computer", "ou"), default="any"),
        Param("query", "string", "Name fragment."),
        Param("limit", "integer", "Maximum results.", default=100, minimum=1),
    ),
))

# ---- writes --------------------------------------------------------------

register(Op(
    name="ad_user_create", toolset=TOOLSET, tier="W", script="ad_user_create",
    description=(
        "Create a user. Give an OU, or a template user whose OU, department and (non-privileged) groups are copied. "
        "If no password is given a strong one is generated and returned once."
    ),
    params=(
        Param("sam", "string", "sAMAccountName (logon name) for the new user.", required=True),
        Param("given_name", "string", "First name."),
        Param("surname", "string", "Last name."),
        Param("display_name", "string", "Display name; defaults to 'First Last'."),
        Param("ou", "string", "DN of the OU to create the user in.", ps="Path"),
        Param("template", "string", "sAMAccountName of a user to copy OU, department and groups from."),
        Param("email", "string", "Email address."),
        Param("title", "string", "Job title."),
        Param("department", "string", "Department."),
        Param("description", "string", "Description."),
        Param("password", "string", "Initial password. Omit to generate one."),
        Param("must_change", "boolean", "Require a password change at first logon.", default=True),
        Param("enabled", "boolean", "Create the account enabled.", default=True),
    ),
    target=lambda a: a.get("sam", ""),
    identities=("sam",),
    inject=lambda s: {"PrivilegedGroups": privileged_group_names(s)},
))

register(Op(
    name="ad_user_update", toolset=TOOLSET, tier="W", script="ad_user_update",
    description="Change a user's profile attributes (display name, names, email, title, department, office, phone, description, manager).",
    params=(
        IDENTITY,
        Param("display_name", "string", "Display name."),
        Param("given_name", "string", "First name."),
        Param("surname", "string", "Last name."),
        Param("email", "string", "Email address."),
        Param("title", "string", "Job title."),
        Param("department", "string", "Department."),
        Param("office", "string", "Office."),
        Param("phone", "string", "Office phone."),
        Param("description", "string", "Description."),
        Param("manager", "string", "sAMAccountName of the manager."),
    ),
    identities=("identity",),
))

register(Op(
    name="ad_user_reset_password", toolset=TOOLSET, tier="W", script="ad_user_reset_password",
    description="Reset a user's password (generated and returned once if not given), optionally forcing a change at next logon and unlocking.",
    params=(
        IDENTITY,
        Param("password", "string", "New password. Omit to generate one."),
        Param("must_change", "boolean", "Require a change at next logon.", default=True),
        Param("unlock", "boolean", "Unlock the account if it is locked.", default=True),
    ),
    identities=("identity",),
))

for _name, _desc in (
    ("ad_user_unlock", "Unlock a locked-out user account."),
    ("ad_user_enable", "Enable a disabled user account."),
):
    register(Op(name=_name, toolset=TOOLSET, tier="W", script=_name, description=_desc, params=(IDENTITY,), identities=("identity",)))

register(Op(
    name="ad_user_disable", toolset=TOOLSET, tier="W", script="ad_user_disable",
    description="Disable a user account, optionally stamping the description (e.g. 'Disabled 2026-11-05 ticket 4411').",
    params=(IDENTITY, Param("note", "string", "Text to write into the description.")),
    identities=("identity",),
))

register(Op(
    name="ad_user_move", toolset=TOOLSET, tier="W", script="ad_user_move",
    description="Move a user to another OU.",
    params=(IDENTITY, Param("target_ou", "string", "DN of the destination OU.", required=True)),
    identities=("identity",),
))

_MEMBERS = (
    Param("group", "string", "Group name, sAMAccountName or DN.", required=True),
    Param("members", "array", "sAMAccountNames of users, groups or computers (computers end in $).", required=True),
)

register(Op(
    name="ad_group_add_member", toolset=TOOLSET, tier="W", script="ad_group_add_member",
    description="Add members to a group. Privileged groups (Domain Admins etc.) make this a high-risk change.",
    params=_MEMBERS, target=_members_target("←"), identities=("group", "members"),
    escalate=_privileged_change, preview=True,
))

register(Op(
    name="ad_group_remove_member", toolset=TOOLSET, tier="W", script="ad_group_remove_member",
    description="Remove members from a group. Privileged groups make this a high-risk change.",
    params=_MEMBERS, target=_members_target("→"), identities=("group", "members"),
    escalate=_privileged_change, preview=True,
))

register(Op(
    name="ad_recycle_bin_restore", toolset=TOOLSET, tier="W", script="ad_recycle_bin_restore",
    description="Restore a deleted object from the AD Recycle Bin (by objectGUID from ad_recycle_bin_list), optionally into another OU.",
    params=(
        Param("identity", "string", "objectGUID of the deleted object.", required=True),
        Param("target_ou", "string", "DN to restore into instead of the last known parent."),
    ),
))

register(Op(
    name="ad_user_delete", toolset=TOOLSET, tier="H", script="ad_user_delete",
    description="Delete a user account. High-risk: shows a preview with current groups and Recycle Bin state first.",
    params=(IDENTITY,), identities=("identity",), preview=True,
))
```

`sysadmin/ops/__init__.py`:
```python
"""Importing this package registers every operation in sysadmin.registry.OPS."""

from . import domain, users  # noqa: F401
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.venv/bin/pytest tests/test_ops_users.py`
Expected: `25 passed`

- [ ] **Step 5: Commit**

```bash
git add sysadmin/ops/users.py sysadmin/ops/__init__.py tests/test_ops_users.py
git commit -m "feat: user and group operations

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: User and group scripts

**Files:**
- Create (17): `sysadmin/scripts/ad_user_get.ps1`, `ad_user_list.ps1`, `ad_lockout_source.ps1`, `ad_group_get.ps1`, `ad_group_list.ps1`, `ad_recycle_bin_list.ps1`, `ad_user_create.ps1`, `ad_user_update.ps1`, `ad_user_reset_password.ps1`, `ad_user_unlock.ps1`, `ad_user_enable.ps1`, `ad_user_disable.ps1`, `ad_user_move.ps1`, `ad_group_add_member.ps1`, `ad_group_remove_member.ps1`, `ad_recycle_bin_restore.ps1`, `ad_user_delete.ps1`
- Modify: `plugin.yaml` (`provides_tools`)

**Interfaces:**
- Consumes: prelude helpers (`Invoke-Op`, `Iso`, `Get-CnName`, `Get-ParentDn`, `New-HermesPassword`, `ConvertTo-HermesSecure`, `Assert-Hermes`, `Get-HermesFanout`).
- Produces: the data shapes the dashboard Users tab reads: user rows `{sam, name, display_name, dn, ou, enabled, locked, last_logon, password_expires, password_never_expires, password_expired, email, title, department, groups}`.

- [ ] **Step 1: Write the scripts**

`ad_user_get.ps1`:
```powershell
param([Parameter(Mandatory)][string]$Identity)
Invoke-Op {
    $props = 'DisplayName', 'EmailAddress', 'Title', 'Department', 'Office', 'telephoneNumber', 'Description', 'Manager',
        'Enabled', 'LockedOut', 'lockoutTime', 'badPwdCount', 'PasswordLastSet', 'PasswordNeverExpires', 'PasswordExpired',
        'msDS-UserPasswordExpiryTimeComputed', 'LastLogonDate', 'whenCreated', 'whenChanged', 'MemberOf',
        'AccountExpirationDate', 'UserPrincipalName', 'CannotChangePassword'
    $u = Get-ADUser -Identity $Identity -Properties $props
    $ft = $u.'msDS-UserPasswordExpiryTimeComputed'
    $expires = $null
    if (-not $u.PasswordNeverExpires -and $ft -gt 0 -and $ft -lt [long]::MaxValue) { $expires = [datetime]::FromFileTimeUtc($ft).ToString('o') }
    @{
        sam                    = $u.SamAccountName
        name                   = $u.Name
        display_name           = $u.DisplayName
        upn                    = $u.UserPrincipalName
        dn                     = $u.DistinguishedName
        ou                     = (Get-ParentDn $u.DistinguishedName)
        email                  = $u.EmailAddress
        title                  = $u.Title
        department             = $u.Department
        office                 = $u.Office
        phone                  = $u.telephoneNumber
        description            = "$($u.Description)"
        manager                = (Get-CnName $u.Manager)
        enabled                = [bool]$u.Enabled
        locked                 = [bool]$u.LockedOut
        lockout_time           = $(if ($u.lockoutTime) { [datetime]::FromFileTimeUtc($u.lockoutTime).ToString('o') } else { $null })
        bad_password_count     = $u.badPwdCount
        password_last_set      = (Iso $u.PasswordLastSet)
        password_expires       = $expires
        password_never_expires = [bool]$u.PasswordNeverExpires
        password_expired       = [bool]$u.PasswordExpired
        cannot_change_password = [bool]$u.CannotChangePassword
        account_expires        = (Iso $u.AccountExpirationDate)
        last_logon             = (Iso $u.LastLogonDate)
        created                = (Iso $u.whenCreated)
        changed                = (Iso $u.whenChanged)
        groups                 = @($u.MemberOf | ForEach-Object { Get-CnName $_ } | Sort-Object)
    }
}
```

`ad_user_list.ps1`:
```powershell
param(
    [string]$Query,
    [string]$SearchBase,
    [ValidateSet('any', 'enabled', 'disabled', 'locked')][string]$Status = 'any',
    [ValidateSet('any', 'expired', 'expiring', 'never_expires')][string]$Password = 'any',
    [int]$StaleDays = 0,
    [int]$ExpiringDays = 7,
    [bool]$Privileged = $false,
    [int]$Limit = 200
)
Invoke-Op {
    $parts = @('(objectCategory=person)', '(objectClass=user)')
    if ($Status -eq 'disabled') { $parts += '(userAccountControl:1.2.840.113556.1.4.803:=2)' }
    if ($Status -eq 'enabled') { $parts += '(!(userAccountControl:1.2.840.113556.1.4.803:=2))' }
    if ($Password -eq 'never_expires') { $parts += '(userAccountControl:1.2.840.113556.1.4.803:=65536)' }
    if ($Query) {
        $escaped = $Query -replace '\\', '\5c' -replace '\(', '\28' -replace '\)', '\29' -replace "`0", '\00'
        $parts += "(anr=$escaped)"
    }
    $splat = @{
        LDAPFilter = '(&' + ($parts -join '') + ')'
        Properties = @('DisplayName', 'EmailAddress', 'Title', 'Department', 'Enabled', 'LockedOut', 'PasswordLastSet',
            'PasswordNeverExpires', 'PasswordExpired', 'msDS-UserPasswordExpiryTimeComputed', 'LastLogonDate', 'MemberOf')
    }
    if ($SearchBase) { $splat.SearchBase = $SearchBase }
    $nowUtc = (Get-Date).ToUniversalTime()
    $staleCutoff = (Get-Date).AddDays(-$StaleDays)
    $rows = @(foreach ($u in @(Get-ADUser @splat | Sort-Object Name)) {
        $ft = $u.'msDS-UserPasswordExpiryTimeComputed'
        $exp = $null
        if (-not $u.PasswordNeverExpires -and $ft -gt 0 -and $ft -lt [long]::MaxValue) { $exp = [datetime]::FromFileTimeUtc($ft) }
        if ($Status -eq 'locked' -and -not $u.LockedOut) { continue }
        if ($Password -eq 'expired' -and -not ($u.PasswordExpired -or ($exp -and $exp -lt $nowUtc))) { continue }
        if ($Password -eq 'expiring' -and -not ($exp -and $exp -gt $nowUtc -and $exp -lt $nowUtc.AddDays($ExpiringDays))) { continue }
        if ($StaleDays -gt 0 -and $u.LastLogonDate -and $u.LastLogonDate -gt $staleCutoff) { continue }
        @{
            sam                    = $u.SamAccountName
            name                   = $u.Name
            display_name           = $u.DisplayName
            dn                     = $u.DistinguishedName
            ou                     = (Get-ParentDn $u.DistinguishedName)
            enabled                = [bool]$u.Enabled
            locked                 = [bool]$u.LockedOut
            last_logon             = (Iso $u.LastLogonDate)
            password_last_set      = (Iso $u.PasswordLastSet)
            password_expires       = $(if ($exp) { $exp.ToString('o') } else { $null })
            password_never_expires = [bool]$u.PasswordNeverExpires
            password_expired       = [bool]($u.PasswordExpired -or ($exp -and $exp -lt $nowUtc))
            email                  = $u.EmailAddress
            title                  = $u.Title
            department             = $u.Department
            groups                 = @($u.MemberOf | ForEach-Object { Get-CnName $_ })
        }
    })
    $total = $rows.Count
    if (-not $Privileged -and $rows.Count -gt $Limit) { $rows = @($rows[0..($Limit - 1)]) }
    @{ items = $rows; total = $total; limit = $Limit }
}
```

`ad_lockout_source.ps1`:
```powershell
param(
    [Parameter(Mandatory)][string]$Identity,
    [int]$Hours = 24
)
Invoke-Op {
    $u = Get-ADUser -Identity $Identity -Properties LockedOut, lockoutTime
    $pdc = (Get-ADDomain).PDCEmulator
    $byDc = @(foreach ($dc in @(Get-ADDomainController -Filter * | ForEach-Object { $_.HostName })) {
        try {
            $x = Get-ADUser -Identity $u.SamAccountName -Server $dc -Properties badPwdCount, badPasswordTime
            @{ dc = $dc; count = $x.badPwdCount; last = $(if ($x.badPasswordTime) { [datetime]::FromFileTimeUtc($x.badPasswordTime).ToString('o') } else { $null }) }
        } catch {
            @{ dc = $dc; count = $null; last = $null; error = "$($_.Exception.Message)" }
        }
    })
    $remote = Get-HermesFanout -Computers @($pdc) -ArgumentList @($u.SamAccountName, $Hours) -Script {
        param($Sam, $H)
        $start = (Get-Date).AddHours(-$H)
        Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4740; StartTime = $start } -ErrorAction SilentlyContinue |
            Where-Object { $_.Properties[0].Value -eq $Sam } |
            Select-Object -First 200 |
            ForEach-Object { [pscustomobject]@{ time = $_.TimeCreated.ToUniversalTime().ToString('o'); source = "$($_.Properties[1].Value)" } }
    }
    @{
        identity           = $u.SamAccountName
        locked             = [bool]$u.LockedOut
        lockout_time       = $(if ($u.lockoutTime) { [datetime]::FromFileTimeUtc($u.lockoutTime).ToString('o') } else { $null })
        pdc                = $pdc
        hours              = $Hours
        events             = @($remote.results | ForEach-Object { @{ time = $_.time; source = $_.source; dc = $_.host } })
        bad_password_by_dc = $byDc
        errors             = $remote.errors
    }
}
```

`ad_group_get.ps1`:
```powershell
param(
    [Parameter(Mandatory)][string]$Identity,
    [int]$Limit = 500
)
Invoke-Op {
    $g = Get-ADGroup -Identity $Identity -Properties Description, ManagedBy, member, whenChanged
    try {
        $members = @(Get-ADGroupMember -Identity $g | Select-Object -First $Limit | ForEach-Object {
            @{ name = $_.Name; sam = $_.SamAccountName; class = $_.objectClass; dn = $_.distinguishedName }
        })
    } catch {
        $members = @($g.member | Select-Object -First $Limit | ForEach-Object { @{ name = (Get-CnName $_); dn = $_ } })
    }
    @{
        name         = $g.Name
        sam          = $g.SamAccountName
        dn           = $g.DistinguishedName
        scope        = "$($g.GroupScope)"
        category     = "$($g.GroupCategory)"
        description  = "$($g.Description)"
        managed_by   = (Get-CnName $g.ManagedBy)
        member_count = @($g.member).Count
        members      = $members
        changed      = (Iso $g.whenChanged)
    }
}
```

`ad_group_list.ps1`:
```powershell
param(
    [string]$Query,
    [int]$Limit = 100
)
Invoke-Op {
    $filter = '(objectClass=group)'
    if ($Query) {
        $escaped = $Query -replace '\\', '\5c' -replace '\(', '\28' -replace '\)', '\29' -replace "`0", '\00'
        $filter = "(&(objectClass=group)(anr=$escaped))"
    }
    $items = @(Get-ADGroup -LDAPFilter $filter -ResultSetSize $Limit -Properties Description, member | Sort-Object Name | ForEach-Object {
        @{
            name         = $_.Name
            sam          = $_.SamAccountName
            dn           = $_.DistinguishedName
            scope        = "$($_.GroupScope)"
            category     = "$($_.GroupCategory)"
            description  = "$($_.Description)"
            member_count = @($_.member).Count
        }
    })
    @{ items = $items; truncated = ($items.Count -ge $Limit) }
}
```

`ad_recycle_bin_list.ps1`:
```powershell
param(
    [ValidateSet('any', 'user', 'group', 'computer', 'ou')][string]$Kind = 'any',
    [string]$Query,
    [int]$Limit = 100
)
Invoke-Op {
    $classes = @{ user = 'user'; group = 'group'; computer = 'computer'; ou = 'organizationalUnit' }
    $items = @(Get-ADObject -Filter 'isDeleted -eq $true' -IncludeDeletedObjects -Properties 'msDS-LastKnownRDN', lastKnownParent, whenChanged, sAMAccountName |
        Where-Object { $_.Name -ne 'Deleted Objects' } |
        Where-Object { $Kind -eq 'any' -or $_.ObjectClass -eq $classes[$Kind] } |
        Where-Object { -not $Query -or "$($_.'msDS-LastKnownRDN')" -like "*$Query*" -or "$($_.sAMAccountName)" -like "*$Query*" } |
        Sort-Object whenChanged -Descending |
        Select-Object -First $Limit |
        ForEach-Object {
            @{
                guid              = "$($_.ObjectGUID)"
                name              = "$($_.'msDS-LastKnownRDN')"
                sam               = $_.sAMAccountName
                class             = $_.ObjectClass
                last_known_parent = $_.lastKnownParent
                deleted           = (Iso $_.whenChanged)
            }
        })
    @{ items = $items }
}
```

`ad_user_create.ps1`:
```powershell
param(
    [Parameter(Mandatory)][string]$Sam,
    [string]$GivenName,
    [string]$Surname,
    [string]$DisplayName,
    [string]$Path,
    [string]$Template,
    [string]$Email,
    [string]$Title,
    [string]$Department,
    [string]$Description,
    [string]$Password,
    [bool]$MustChange = $true,
    [bool]$Enabled = $true,
    [string[]]$PrivilegedGroups = @()
)
Invoke-Op {
    $tpl = $null
    if ($Template) {
        $tpl = Get-ADUser -Identity $Template -Properties MemberOf, Department
        if (-not $Path) { $Path = Get-ParentDn $tpl.DistinguishedName }
        if (-not $Department) { $Department = $tpl.Department }
    }
    Assert-Hermes ([bool]$Path) 'Give an OU (ou) or a template user to copy the OU from.'
    $domain = Get-ADDomain
    if (-not $DisplayName) { $DisplayName = (@($GivenName, $Surname) | Where-Object { $_ }) -join ' ' }
    if (-not $DisplayName) { $DisplayName = $Sam }
    $generated = -not $Password
    if ($generated) { $Password = New-HermesPassword }
    $splat = @{
        Name                  = $DisplayName
        SamAccountName        = $Sam
        UserPrincipalName     = "$Sam@$($domain.DNSRoot)"
        DisplayName           = $DisplayName
        Path                  = $Path
        AccountPassword       = (ConvertTo-HermesSecure $Password)
        Enabled               = $Enabled
        ChangePasswordAtLogon = $MustChange
        PassThru              = $true
    }
    foreach ($pair in @(@('GivenName', $GivenName), @('Surname', $Surname), @('EmailAddress', $Email), @('Title', $Title), @('Department', $Department), @('Description', $Description))) {
        if ($pair[1]) { $splat[$pair[0]] = $pair[1] }
    }
    $u = New-ADUser @splat
    $copied = @()
    $skipped = @()
    if ($tpl) {
        $deny = @($PrivilegedGroups | ForEach-Object { "$_".ToLower() })
        foreach ($g in @($tpl.MemberOf)) {
            $cn = Get-CnName $g
            if ($deny -contains $cn.ToLower()) { $skipped += $cn; continue }
            Add-ADGroupMember -Identity $g -Members $u.SamAccountName
            $copied += $cn
        }
    }
    $out = @{
        sam             = $u.SamAccountName
        dn              = $u.DistinguishedName
        upn             = $u.UserPrincipalName
        enabled         = $Enabled
        must_change     = $MustChange
        groups_copied   = $copied
        groups_skipped  = $skipped
        password_source = $(if ($generated) { 'generated' } else { 'provided' })
    }
    if ($generated) { $out.password = $Password }
    $out
}
```

`ad_user_update.ps1`:
```powershell
param(
    [Parameter(Mandatory)][string]$Identity,
    [string]$DisplayName,
    [string]$GivenName,
    [string]$Surname,
    [string]$Email,
    [string]$Title,
    [string]$Department,
    [string]$Office,
    [string]$Phone,
    [string]$Description,
    [string]$Manager
)
Invoke-Op {
    $map = [ordered]@{
        DisplayName = $DisplayName; GivenName = $GivenName; Surname = $Surname; EmailAddress = $Email
        Title = $Title; Department = $Department; Office = $Office; OfficePhone = $Phone; Description = $Description
    }
    $splat = @{ Identity = $Identity }
    foreach ($k in $map.Keys) { if ($map[$k]) { $splat[$k] = $map[$k] } }
    if ($Manager) { $splat.Manager = (Get-ADUser -Identity $Manager).DistinguishedName }
    Assert-Hermes ($splat.Count -gt 1) 'Give at least one attribute to change.'
    Set-ADUser @splat
    @{ identity = $Identity; changed = @($splat.Keys | Where-Object { $_ -ne 'Identity' } | Sort-Object) }
}
```

`ad_user_reset_password.ps1`:
```powershell
param(
    [Parameter(Mandatory)][string]$Identity,
    [string]$Password,
    [bool]$MustChange = $true,
    [bool]$Unlock = $true
)
Invoke-Op {
    $u = Get-ADUser -Identity $Identity -Properties LockedOut
    $generated = -not $Password
    if ($generated) { $Password = New-HermesPassword }
    Set-ADAccountPassword -Identity $u -Reset -NewPassword (ConvertTo-HermesSecure $Password)
    Set-ADUser -Identity $u -ChangePasswordAtLogon $MustChange
    $unlocked = $false
    if ($Unlock -and $u.LockedOut) {
        Unlock-ADAccount -Identity $u
        $unlocked = $true
    }
    $out = @{ identity = $u.SamAccountName; must_change = $MustChange; unlocked = $unlocked; password_source = $(if ($generated) { 'generated' } else { 'provided' }) }
    if ($generated) { $out.password = $Password }
    $out
}
```

`ad_user_unlock.ps1`:
```powershell
param([Parameter(Mandatory)][string]$Identity)
Invoke-Op {
    $u = Get-ADUser -Identity $Identity -Properties LockedOut
    if ($u.LockedOut) { Unlock-ADAccount -Identity $u }
    @{ identity = $u.SamAccountName; was_locked = [bool]$u.LockedOut; locked = $false }
}
```

`ad_user_enable.ps1`:
```powershell
param([Parameter(Mandatory)][string]$Identity)
Invoke-Op {
    $u = Get-ADUser -Identity $Identity
    Enable-ADAccount -Identity $u
    @{ identity = $u.SamAccountName; enabled = $true }
}
```

`ad_user_disable.ps1`:
```powershell
param(
    [Parameter(Mandatory)][string]$Identity,
    [string]$Note
)
Invoke-Op {
    $u = Get-ADUser -Identity $Identity
    Disable-ADAccount -Identity $u
    if ($Note) { Set-ADUser -Identity $u -Description $Note }
    @{ identity = $u.SamAccountName; enabled = $false; note = $Note }
}
```

`ad_user_move.ps1`:
```powershell
param(
    [Parameter(Mandatory)][string]$Identity,
    [Parameter(Mandatory)][string]$TargetOu
)
Invoke-Op {
    $u = Get-ADUser -Identity $Identity
    $from = Get-ParentDn $u.DistinguishedName
    Move-ADObject -Identity $u.DistinguishedName -TargetPath $TargetOu
    @{ identity = $u.SamAccountName; from = $from; to = $TargetOu }
}
```

`ad_group_add_member.ps1`:
```powershell
param(
    [Parameter(Mandatory)][string]$Group,
    [Parameter(Mandatory)][string[]]$Members,
    [switch]$Preview
)
Invoke-Op {
    $g = Get-ADGroup -Identity $Group -Properties member
    if ($Preview) {
        return @{
            summary = "Add $($Members -join ', ') to $($g.Name)"
            changes = @(foreach ($m in $Members) { "Add-ADGroupMember -Identity '$($g.Name)' -Members '$m'" })
            current = @{ member_count = @($g.member).Count; members = @($g.member | Select-Object -First 20 | ForEach-Object { Get-CnName $_ }) }
        }
    }
    Add-ADGroupMember -Identity $g -Members $Members -Confirm:$false
    @{ group = $g.Name; added = @($Members) }
}
```

`ad_group_remove_member.ps1`:
```powershell
param(
    [Parameter(Mandatory)][string]$Group,
    [Parameter(Mandatory)][string[]]$Members,
    [switch]$Preview
)
Invoke-Op {
    $g = Get-ADGroup -Identity $Group -Properties member
    if ($Preview) {
        return @{
            summary = "Remove $($Members -join ', ') from $($g.Name)"
            changes = @(foreach ($m in $Members) { "Remove-ADGroupMember -Identity '$($g.Name)' -Members '$m'" })
            current = @{ member_count = @($g.member).Count; members = @($g.member | Select-Object -First 20 | ForEach-Object { Get-CnName $_ }) }
        }
    }
    Remove-ADGroupMember -Identity $g -Members $Members -Confirm:$false
    @{ group = $g.Name; removed = @($Members) }
}
```

`ad_recycle_bin_restore.ps1`:
```powershell
param(
    [Parameter(Mandatory)][string]$Identity,
    [string]$TargetOu
)
Invoke-Op {
    $o = Get-ADObject -Identity $Identity -IncludeDeletedObjects -Properties 'msDS-LastKnownRDN', lastKnownParent
    $splat = @{ Identity = $o; PassThru = $true }
    if ($TargetOu) { $splat.TargetPath = $TargetOu }
    $r = Restore-ADObject @splat
    @{ restored = "$($o.'msDS-LastKnownRDN')"; dn = $r.DistinguishedName; to = $(if ($TargetOu) { $TargetOu } else { $o.lastKnownParent }) }
}
```

`ad_user_delete.ps1`:
```powershell
param(
    [Parameter(Mandatory)][string]$Identity,
    [switch]$Preview
)
Invoke-Op {
    $u = Get-ADUser -Identity $Identity -Properties MemberOf, Enabled, LastLogonDate
    $recycle = @(Get-ADOptionalFeature -Filter "Name -eq 'Recycle Bin Feature'" | Where-Object { $_.EnabledScopes.Count -gt 0 }).Count -gt 0
    if ($Preview) {
        $note = if ($recycle) { 'AD Recycle Bin is enabled: the account can be restored with ad_recycle_bin_restore.' } else { 'AD Recycle Bin is NOT enabled: this cannot be undone without an authoritative restore.' }
        return @{
            summary = "Delete user $($u.SamAccountName) ($($u.DistinguishedName))"
            changes = @("Remove-ADUser -Identity '$($u.DistinguishedName)'", $note)
            current = @{ enabled = [bool]$u.Enabled; last_logon = (Iso $u.LastLogonDate); groups = @($u.MemberOf | ForEach-Object { Get-CnName $_ }) }
        }
    }
    Remove-ADUser -Identity $u -Confirm:$false
    @{ deleted = $u.DistinguishedName; sam = $u.SamAccountName; recycle_bin = $recycle }
}
```

- [ ] **Step 2: Update `plugin.yaml` `provides_tools`** to the full sorted list:

```yaml
provides_tools:
  - ad_connection_test
  - ad_dc_health
  - ad_dc_list
  - ad_domain_overview
  - ad_group_add_member
  - ad_group_get
  - ad_group_list
  - ad_group_remove_member
  - ad_lockout_source
  - ad_recycle_bin_list
  - ad_recycle_bin_restore
  - ad_search
  - ad_user_create
  - ad_user_delete
  - ad_user_disable
  - ad_user_enable
  - ad_user_get
  - ad_user_list
  - ad_user_move
  - ad_user_reset_password
  - ad_user_unlock
  - ad_user_update
```

- [ ] **Step 3: Run the suite (contract + parse + manifest)**

Run: `.venv/bin/pytest`
Expected: all pass, including `test_every_op_has_a_contract_conforming_script[ad_user_*]`, `test_no_orphan_scripts`, `test_all_scripts_parse`, and `test_manifest_declares_exactly_what_register_registers`.

- [ ] **Step 4: Live smoke in the test OU** (env vars from Phase 2 Task 6; replace the OU DN with yours)

```bash
OU='OU=HermesTest,DC=corp,DC=example,DC=local'
.venv/bin/python scripts/smoke.py ad_user_create "{\"sam\": \"zz-hermes-test-1\", \"given_name\": \"Zed\", \"surname\": \"Test\", \"ou\": \"$OU\"}" --approve
.venv/bin/python scripts/smoke.py ad_user_get '{"identity": "zz-hermes-test-1"}'
.venv/bin/python scripts/smoke.py ad_user_reset_password '{"identity": "zz-hermes-test-1"}' --approve
.venv/bin/python scripts/smoke.py ad_user_list "{\"ou\": \"$OU\"}"
.venv/bin/python scripts/smoke.py ad_group_add_member '{"group": "Domain Admins", "members": ["zz-hermes-test-1"]}' --preview
.venv/bin/python scripts/smoke.py ad_lockout_source '{"identity": "zz-hermes-test-1"}'
.venv/bin/python scripts/smoke.py ad_user_delete '{"identity": "zz-hermes-test-1"}' --preview
.venv/bin/python scripts/smoke.py ad_user_delete '{"identity": "zz-hermes-test-1"}' --approve
.venv/bin/python scripts/smoke.py ad_recycle_bin_list '{"query": "zz-hermes"}'
```
Expected: every command prints `"ok": true`. The create and reset results include a 20-character `password`. The Domain Admins preview lists current members and makes no change (confirm with `ad_group_get`). `ad_user_delete --preview` reports the Recycle Bin state. The deleted user appears in the Recycle Bin list (if the Recycle Bin is enabled).

- [ ] **Step 5: Commit**

```bash
git add sysadmin/scripts plugin.yaml
git commit -m "feat: user and group PowerShell scripts

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
