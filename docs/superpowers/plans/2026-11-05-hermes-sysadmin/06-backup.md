# Phase 6 — Backup control (Windows Server Backup)

> Part of the [Hermes Sysadmin plan](README.md). Requires Phase 2 and the Phase 5 prelude helpers (`Get-HermesTargets`, `Invoke-HermesOne`). Follows the surface pattern described at the top of Phase 2.

**Deliverable:** 6 backup tools (toolset `ad_backup`). They give per-host backup status with stale/failed/running classification against `backup_stale_days`, plus a versions list and job progress with event history. Backups start as server-side async jobs and can be cancelled. The scheduled-policy change is high-risk with a preview. These tools drive the Backups tab cards in the mockup.

| Op | Tier | Notes |
|---|---|---|
| `backup_status` | R | hosts / OU / all servers; post adds `state` (`ok`/`bad`/`run`/`none`), `age_hours`, `stale`, `message`, `summary` |
| `backup_versions` | R | one host; newest first |
| `backup_jobs` | R | one host; current job (with `percent`) + last 30 Backup-log events, classified |
| `backup_start` | W | `kind` = `system_state` / `policy` / `volumes`; `Start-WBBackup -Async`; returns at once |
| `backup_cancel` | W | `wbadmin stop job -quiet` |
| `backup_set_policy` | H | replaces the scheduled policy; preview shows current → new |

Restores stay out of scope (spec §13). The `backup-recovery-guide` skill (Phase 7) documents them as a runbook.

---

### Task 1: Backup ops (Python)

**Files:**
- Create: `sysadmin/ops/backup.py`
- Modify: `sysadmin/ops/__init__.py`
- Test: `tests/test_ops_backup.py`

**Interfaces:**
- Consumes: `Op`, `Param`, `register`, `Settings.backup_stale_days`, `Settings.server_search_base`.
- Produces:
  - Helpers: `parse_iso(text) -> datetime | None` (tolerates .NET's 7-digit fractions and `Z`), `backup_state(host: Mapping, stale_days: int, now: datetime) -> dict` (returns `state`, `stale`, `age_hours`, `message`), `event_outcome(event: Mapping) -> str`, `status_summary(data, stale_days, now) -> dict` (the `backup_status` post calls it with the current UTC time).
  - Status row: `{host, installed, policy, last_success, last_backup, last_result_hr, message, next_run, versions, target, last_system_state, job: {running, type, operation, percent, started} | None, state, stale, age_hours}`.
  - Summary: `{hosts, ok, bad, running, not_configured, unreachable, oldest_system_state: {host, age_hours} | None}`. Phase 8's `/overview` uses `oldest_system_state` for the "Oldest system-state backup" KPI.

- [ ] **Step 1: Write the failing test** — `tests/test_ops_backup.py`

```python
from datetime import datetime, timezone

import pytest

from sysadmin import ops  # noqa: F401
from sysadmin.config import Settings
from sysadmin.errors import InvalidArguments
from sysadmin.ops.backup import backup_state, event_outcome, parse_iso, status_summary
from sysadmin.policy import decide
from sysadmin.registry import OPS, coerce_args, ps_params

NOW = datetime(2026, 11, 5, 12, 0, tzinfo=timezone.utc)

EXPECTED = {
    "backup_status": ("R", False), "backup_versions": ("R", False), "backup_jobs": ("R", False),
    "backup_start": ("W", False), "backup_cancel": ("W", False), "backup_set_policy": ("H", True),
}

HEALTHY = {
    "host": "DC01", "installed": True, "policy": True, "last_result_hr": 0, "message": "",
    "versions": 14, "last_system_state": "2026-11-05T02:00:00.0000000Z", "job": None,
}


@pytest.mark.parametrize("name", sorted(EXPECTED))
def test_tiers(name):
    assert (OPS[name].tier, OPS[name].preview) == EXPECTED[name]
    assert OPS[name].toolset == "ad_backup"


def test_parse_iso_handles_dotnet_round_trip_format():
    assert parse_iso("2026-11-05T02:00:00.1234567Z") == datetime(2026, 11, 5, 2, 0, 0, 123456, tzinfo=timezone.utc)
    assert parse_iso("2026-11-05T02:00:00Z") == datetime(2026, 11, 5, 2, 0, tzinfo=timezone.utc)
    assert parse_iso(None) is None and parse_iso("not a date") is None


@pytest.mark.parametrize(
    "changes, state, stale, message",
    [
        ({}, "ok", False, ""),
        ({"last_system_state": "2026-10-27T23:00:00Z"}, "bad", True, "System-state backup is 8.5 days old"),
        ({"last_system_state": None}, "bad", True, "No system-state backup found"),
        ({"last_result_hr": -2139619131, "message": "The backup target volume was not found."}, "bad", False,
         "The backup target volume was not found."),
        ({"last_result_hr": -2139619131}, "bad", False, "Last backup failed (0x807800C5)"),
        ({"job": {"running": True, "percent": 62}}, "run", False, ""),
        ({"installed": False}, "none", False, "Windows Server Backup feature not installed"),
        ({"policy": False, "versions": 0, "last_system_state": None}, "none", False, "No backup policy configured"),
    ],
)
def test_backup_state(changes, state, stale, message):
    out = backup_state({**HEALTHY, **changes}, 7, NOW)
    assert (out["state"], out["stale"], out["message"]) == (state, stale, message)


def test_backup_state_age_hours():
    assert backup_state(HEALTHY, 7, NOW)["age_hours"] == 10.0


def test_status_post_summary_and_oldest():
    data = {
        "results": [
            HEALTHY,
            {**HEALTHY, "host": "SRV-FS01", "last_system_state": "2026-10-27T12:00:00Z"},
            {**HEALTHY, "host": "SRV-RDS01", "installed": False},
        ],
        "errors": [{"host": "SRV-OLD", "message": "WinRM cannot complete the operation"}],
    }
    out = status_summary(data, 7, NOW)
    assert [h["state"] for h in out["items"]] == ["ok", "bad", "none"]
    assert out["summary"] == {
        "hosts": 4, "ok": 1, "bad": 1, "running": 0, "not_configured": 1, "unreachable": 1,
        "oldest_system_state": {"host": "SRV-FS01", "age_hours": 216.0},
    }


@pytest.mark.parametrize(
    "event, outcome",
    [
        ({"id": 1, "level": "Information"}, "started"),
        ({"id": 4, "level": "Information"}, "succeeded"),
        ({"id": 14, "level": "Information"}, "completed"),
        ({"id": 5, "level": "Error"}, "failed"),
        ({"id": 100, "level": "Warning"}, "info"),
    ],
)
def test_event_outcome(event, outcome):
    assert event_outcome(event) == outcome


def test_jobs_post_classifies_history():
    out = OPS["backup_jobs"].post({"current": None, "history": [{"id": 4, "level": "Information"}]}, {}, Settings())
    assert out["history"][0]["outcome"] == "succeeded"


def test_start_kind_is_validated_and_host_maps_to_computer_name():
    with pytest.raises(InvalidArguments):
        coerce_args(OPS["backup_start"], {"host": "SRV1", "kind": "everything"})
    args = coerce_args(OPS["backup_start"], {"host": "SRV1"})
    assert args["kind"] == "system_state"
    assert ps_params(OPS["backup_start"], args)["ComputerName"] == "SRV1"
    assert OPS["backup_status"].inject(Settings(server_search_base="OU=S")) == {"ServerSearchBase": "OU=S"}


def test_set_policy_always_needs_preview_approval():
    d = decide(OPS["backup_set_policy"], {"host": "SRV1", "schedule": ["23:00"], "target": "E:"}, Settings())
    assert (d.action, d.tier, d.needs_preview) == ("approve", "H", True)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_ops_backup.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'sysadmin.ops.backup'`

- [ ] **Step 3: Implement** — `sysadmin/ops/backup.py`

```python
"""Windows Server Backup operations."""

from __future__ import annotations

import re
from datetime import datetime, timezone
from typing import Any, Mapping

from ..registry import Op, Param, register

TOOLSET = "ad_backup"
HOSTS = Param("hosts", "array", "Computer DNS names. Omit both hosts and ou to check every enabled server.")
OU = Param("ou", "string", "DN of an OU whose enabled computers to include.")
HOST = Param("host", "string", "Computer DNS name.", required=True, ps="ComputerName")
_FRACTION = re.compile(r"(\.\d{6})\d+")
_OUTCOMES = {1: "started", 4: "succeeded", 14: "completed"}


def parse_iso(text: Any) -> datetime | None:
    if not isinstance(text, str) or not text:
        return None
    try:
        value = datetime.fromisoformat(_FRACTION.sub(r"\1", text).replace("Z", "+00:00"))
    except ValueError:
        return None
    return value if value.tzinfo else value.replace(tzinfo=timezone.utc)


def backup_state(host: Mapping[str, Any], stale_days: int, now: datetime) -> dict[str, Any]:
    taken = parse_iso(host.get("last_system_state"))
    age = round((now - taken).total_seconds() / 3600, 1) if taken else None
    out: dict[str, Any] = {"state": "ok", "stale": False, "age_hours": age, "message": ""}
    if not host.get("installed"):
        return {**out, "state": "none", "message": "Windows Server Backup feature not installed"}
    if (host.get("job") or {}).get("running"):
        return {**out, "state": "run"}
    if not host.get("policy") and not host.get("versions"):
        return {**out, "state": "none", "message": "No backup policy configured"}
    hr = int(host.get("last_result_hr") or 0)
    if hr != 0:
        return {**out, "state": "bad", "message": str(host.get("message") or "").strip() or f"Last backup failed (0x{hr & 0xFFFFFFFF:08X})"}
    if taken is None:
        return {**out, "state": "bad", "stale": True, "message": "No system-state backup found"}
    if age is not None and age > stale_days * 24:
        return {**out, "state": "bad", "stale": True, "message": f"System-state backup is {round(age / 24, 1)} days old"}
    return out


def event_outcome(event: Mapping[str, Any]) -> str:
    outcome = _OUTCOMES.get(int(event.get("id") or 0))
    if outcome:
        return outcome
    return "failed" if str(event.get("level", "")).lower() in ("error", "critical") else "info"


def _search_base(settings: Any) -> dict[str, Any]:
    return {"ServerSearchBase": settings.server_search_base}


def _post_status(data: Any, args: Mapping[str, Any], settings: Any) -> Any:
    now = datetime.now(timezone.utc)
    return status_summary(data, settings.backup_stale_days, now)


def status_summary(data: Any, stale_days: int, now: datetime) -> dict[str, Any]:
    data = data or {}
    items = [{**h, **backup_state(h, stale_days, now)} for h in data.get("results") or []]
    errors = list(data.get("errors") or [])
    aged = [h for h in items if h["age_hours"] is not None]
    oldest = max(aged, key=lambda h: h["age_hours"]) if aged else None
    return {
        "items": items,
        "errors": errors,
        "stale_days": stale_days,
        "summary": {
            "hosts": len(items) + len(errors),
            "ok": sum(1 for h in items if h["state"] == "ok"),
            "bad": sum(1 for h in items if h["state"] == "bad"),
            "running": sum(1 for h in items if h["state"] == "run"),
            "not_configured": sum(1 for h in items if h["state"] == "none"),
            "unreachable": len(errors),
            "oldest_system_state": {"host": oldest["host"], "age_hours": oldest["age_hours"]} if oldest else None,
        },
    }


def _post_jobs(data: Any, args: Mapping[str, Any], settings: Any) -> Any:
    data = dict(data or {})
    data["history"] = [{**e, "outcome": event_outcome(e)} for e in data.get("history") or []]
    return data


register(Op(
    name="backup_status", toolset=TOOLSET, tier="R", script="backup_status",
    description=(
        "Windows Server Backup status per host: feature installed, policy, last success, last system-state backup, "
        "next run, versions, running job. Flags hosts whose system state is older than backup_stale_days."
    ),
    params=(HOSTS, OU), post=_post_status, inject=_search_base, cache_ttl=60,
))

register(Op(
    name="backup_versions", toolset=TOOLSET, tier="R", script="backup_versions",
    description="Backup versions available on a host (newest first): time, target and what each can recover.",
    params=(HOST,),
))

register(Op(
    name="backup_jobs", toolset=TOOLSET, tier="R", script="backup_jobs",
    description="The running backup job on a host (operation, percent) and recent backup events (started/succeeded/failed).",
    params=(HOST,), post=_post_jobs,
))

register(Op(
    name="backup_start", toolset=TOOLSET, tier="W", script="backup_start",
    description=(
        "Start a one-off backup as a server-side job and return immediately; poll backup_jobs for progress. "
        "kind: system_state (default), policy (run the scheduled policy now), volumes (give 'volumes'). "
        "target: volume (E:) or UNC share; defaults to the scheduled policy's target."
    ),
    params=(
        HOST,
        Param("kind", "string", "What to back up.", enum=("system_state", "policy", "volumes"), default="system_state"),
        Param("target", "string", "Backup target: a volume like E: or a share like \\\\NAS01\\wsb\\SRV1."),
        Param("volumes", "array", "Volumes for kind=volumes, e.g. C:, D:."),
    ),
    target=lambda a: f"{a.get('host', '')} ({str(a.get('kind', 'system_state')).replace('_', ' ')})",
))

register(Op(
    name="backup_cancel", toolset=TOOLSET, tier="W", script="backup_cancel",
    description="Cancel the backup job running on a host.",
    params=(HOST,),
))

register(Op(
    name="backup_set_policy", toolset=TOOLSET, tier="H", script="backup_set_policy",
    description=(
        "Replace a host's scheduled backup policy: daily times (HH:mm), target (volume or UNC share), "
        "system state, bare-metal recovery and volumes. The preview shows current vs new."
    ),
    params=(
        HOST,
        Param("schedule", "array", "Daily start times, e.g. 23:00.", required=True),
        Param("target", "string", "Target volume (E:) or UNC share.", required=True),
        Param("system_state", "boolean", "Include system state.", default=True),
        Param("bare_metal", "boolean", "Include bare-metal recovery.", default=False),
        Param("volumes", "array", "Extra volumes to include, e.g. D:."),
    ),
    preview=True,
))
```

`sysadmin/ops/__init__.py`:
```python
"""Importing this package registers every operation in sysadmin.registry.OPS."""

from . import backup, domain, gpo, rdp, users  # noqa: F401
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.venv/bin/pytest tests/test_ops_backup.py`
Expected: `25 passed`

- [ ] **Step 5: Commit**

```bash
git add sysadmin/ops/backup.py sysadmin/ops/__init__.py tests/test_ops_backup.py
git commit -m "feat: Windows Server Backup operations

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Backup scripts

**Files:**
- Create (6): `sysadmin/scripts/backup_status.ps1`, `backup_versions.ps1`, `backup_jobs.ps1`, `backup_start.ps1`, `backup_cancel.ps1`, `backup_set_policy.ps1`
- Modify: `plugin.yaml` (`provides_tools`)

**Interfaces:**
- Consumes: `Get-HermesTargets`, `Get-HermesFanout`, `Invoke-HermesOne`, `Assert-Hermes`, `$Global:HermesCred`.
- Produces: the row shapes from Task 1. Remote scriptblocks cannot see prelude helpers, so they format dates with an inline `$iso` block (`.ToUniversalTime().ToString('o')`; dates before 1990 such as `DateTime.MinValue` become `$null`).

- [ ] **Step 1: Write the scripts**

`backup_status.ps1`:
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
        $iso = { param($d) if ($d -and ([datetime]$d) -gt [datetime]'1990-01-01') { ([datetime]$d).ToUniversalTime().ToString('o') } else { $null } }
        $feature = Get-WindowsFeature -Name Windows-Server-Backup -ErrorAction SilentlyContinue
        if (-not $feature -or -not $feature.Installed) {
            return [pscustomobject]@{ installed = $false; policy = $false; versions = 0; job = $null }
        }
        Import-Module WindowsServerBackup -ErrorAction Stop
        $s = Get-WBSummary
        $p = Get-WBPolicy -ErrorAction SilentlyContinue
        $target = $null
        if ($p) { $target = (@(Get-WBBackupTarget -Policy $p) | ForEach-Object { if ($_.Path) { "$($_.Path)" } else { "$($_.Label)" } }) -join ', ' }
        $ss = @(Get-WBBackupSet -ErrorAction SilentlyContinue | Where-Object { "$($_.RecoverableItems)" -match 'SystemState' } | Sort-Object BackupTime -Descending | Select-Object -First 1)
        $j = Get-WBJob -ErrorAction SilentlyContinue
        $job = $null
        if ($j -and "$($j.JobState)" -eq 'Running') {
            $pct = $null
            if ("$($j.CurrentOperation)" -match '(\d{1,3})\s*%') { $pct = [int]$Matches[1] }
            $job = [pscustomobject]@{ running = $true; type = "$($j.JobType)"; operation = "$($j.CurrentOperation)"; percent = $pct; started = (& $iso $j.StartTime) }
        }
        [pscustomobject]@{
            installed         = $true
            policy            = [bool]$p
            last_success      = (& $iso $s.LastSuccessfulBackupTime)
            last_backup       = (& $iso $s.LastBackupTime)
            last_result_hr    = [int]$s.LastBackupResultHR
            message           = "$($s.DetailedMessage)"
            next_run          = (& $iso $s.NextBackupTime)
            versions          = [int]$s.NumberOfVersions
            target            = $target
            last_system_state = $(if ($ss.Count -gt 0) { & $iso $ss[0].BackupTime } else { $null })
            job               = $job
        }
    }
    @{ results = $remote.results; errors = $remote.errors; targets = $targets.Count }
}
```

`backup_versions.ps1`:
```powershell
param([Parameter(Mandatory)][string]$ComputerName)
Invoke-Op {
    $r = Invoke-HermesOne -Computer $ComputerName -Script {
        Import-Module WindowsServerBackup -ErrorAction Stop
        $sets = @(Get-WBBackupSet | Sort-Object BackupTime -Descending | Select-Object -First 100)
        [pscustomobject]@{
            items = @($sets | ForEach-Object {
                [pscustomobject]@{
                    version_id  = "$($_.VersionId)"
                    time        = ([datetime]$_.BackupTime).ToUniversalTime().ToString('o')
                    target      = "$($_.BackupTarget.Label)$($_.BackupTarget.Path)"
                    recoverable = "$($_.RecoverableItems)"
                    volumes     = @($_.Volume | ForEach-Object { "$($_.MountPath)" })
                }
            })
        }
    }
    @{ host = $ComputerName; items = @($r.items | ForEach-Object { @{ version_id = $_.version_id; time = $_.time; target = $_.target; recoverable = $_.recoverable; volumes = @($_.volumes) } }) }
}
```

`backup_jobs.ps1`:
```powershell
param([Parameter(Mandatory)][string]$ComputerName)
Invoke-Op {
    $r = Invoke-HermesOne -Computer $ComputerName -Script {
        Import-Module WindowsServerBackup -ErrorAction Stop
        $j = Get-WBJob -ErrorAction SilentlyContinue
        $current = $null
        if ($j -and "$($j.JobState)" -eq 'Running') {
            $pct = $null
            if ("$($j.CurrentOperation)" -match '(\d{1,3})\s*%') { $pct = [int]$Matches[1] }
            $current = [pscustomobject]@{ running = $true; type = "$($j.JobType)"; operation = "$($j.CurrentOperation)"; percent = $pct; started = ([datetime]$j.StartTime).ToUniversalTime().ToString('o') }
        }
        $events = @(Get-WinEvent -LogName 'Microsoft-Windows-Backup' -MaxEvents 30 -ErrorAction SilentlyContinue | ForEach-Object {
            $m = "$($_.Message)"
            [pscustomobject]@{ time = $_.TimeCreated.ToUniversalTime().ToString('o'); id = [int]$_.Id; level = "$($_.LevelDisplayName)"; message = $(if ($m.Length -gt 300) { $m.Substring(0, 300) } else { $m }) }
        })
        [pscustomobject]@{ current = $current; history = $events }
    }
    $cur = $null
    if ($r.current) { $cur = @{ running = $true; type = $r.current.type; operation = $r.current.operation; percent = $r.current.percent; started = $r.current.started } }
    @{
        host    = $ComputerName
        current = $cur
        history = @($r.history | ForEach-Object { @{ time = $_.time; id = $_.id; level = $_.level; message = $_.message } })
    }
}
```

`backup_start.ps1`:
```powershell
param(
    [Parameter(Mandatory)][string]$ComputerName,
    [ValidateSet('system_state', 'policy', 'volumes')][string]$Kind = 'system_state',
    [string]$Target,
    [string[]]$Volumes = @()
)
Invoke-Op {
    Assert-Hermes ($Kind -ne 'volumes' -or $Volumes.Count -gt 0) "kind=volumes needs 'volumes'."
    $r = Invoke-HermesOne -Computer $ComputerName -ArgumentList @($Kind, $Target, $Volumes, $Global:HermesCred) -Script {
        param($K, $T, $V, $C)
        Import-Module WindowsServerBackup -ErrorAction Stop
        $running = Get-WBJob -ErrorAction SilentlyContinue
        if ($running -and "$($running.JobState)" -eq 'Running') { throw 'A backup job is already running on this host.' }
        $scheduled = Get-WBPolicy -ErrorAction SilentlyContinue
        if ($K -eq 'policy') {
            if (-not $scheduled) { throw 'This host has no scheduled backup policy; use kind=system_state or set a policy.' }
            $policy = $scheduled
        } else {
            $policy = New-WBPolicy
            if ($K -eq 'system_state') { Add-WBSystemState -Policy $policy }
            else { foreach ($vol in $V) { Add-WBVolume -Policy $policy -Volume (Get-WBVolume -VolumePath $vol) } }
            if (-not $T) {
                if (-not $scheduled) { throw "Give a 'target' (no scheduled policy to take it from)." }
                $existing = @(Get-WBBackupTarget -Policy $scheduled)[0]
                $T = if ($existing.Path) { "$($existing.Path)" } else { "$($existing.Label)" }
            }
            if ($T -like '\\*') { $bt = New-WBBackupTarget -NetworkPath $T -Credential $C }
            else { $bt = New-WBBackupTarget -VolumePath $T }
            Add-WBBackupTarget -Policy $policy -Target $bt | Out-Null
        }
        Start-WBBackup -Policy $policy -Async | Out-Null
        Start-Sleep -Seconds 2
        $j = Get-WBJob -ErrorAction SilentlyContinue
        [pscustomobject]@{ started = $true; target = $T; state = "$($j.JobState)"; operation = "$($j.CurrentOperation)" }
    }
    @{ host = $ComputerName; kind = $Kind; started = $true; target = $r.target; job = @{ state = $r.state; operation = $r.operation } }
}
```

`backup_cancel.ps1`:
```powershell
param([Parameter(Mandatory)][string]$ComputerName)
Invoke-Op {
    $r = Invoke-HermesOne -Computer $ComputerName -Script {
        $out = (& wbadmin.exe stop job -quiet 2>&1 | Out-String).Trim()
        [pscustomobject]@{ ok = ($LASTEXITCODE -eq 0); output = $(if ($out.Length -gt 400) { $out.Substring($out.Length - 400) } else { $out }) }
    }
    if (-not $r.ok) { throw "wbadmin stop job failed on ${ComputerName}: $($r.output)" }
    @{ host = $ComputerName; cancelled = $true }
}
```

`backup_set_policy.ps1`:
```powershell
param(
    [Parameter(Mandatory)][string]$ComputerName,
    [Parameter(Mandatory)][string[]]$Schedule,
    [Parameter(Mandatory)][string]$Target,
    [bool]$SystemState = $true,
    [bool]$BareMetal = $false,
    [string[]]$Volumes = @(),
    [switch]$Preview
)
Invoke-Op {
    foreach ($t in $Schedule) { Assert-Hermes ($t -match '^([01]?\d|2[0-3]):[0-5]\d$') "Schedule time '$t' must be HH:mm." }
    Assert-Hermes ($SystemState -or $BareMetal -or $Volumes.Count -gt 0) 'The policy must back up something.'
    $r = Invoke-HermesOne -Computer $ComputerName -ArgumentList @($Schedule, $Target, $SystemState, $BareMetal, $Volumes, $Global:HermesCred, [bool]$Preview) -Script {
        param($Sch, $T, $SS, $BMR, $V, $C, $Pv)
        Import-Module WindowsServerBackup -ErrorAction Stop
        $cur = Get-WBPolicy -ErrorAction SilentlyContinue
        $current = [pscustomobject]@{ configured = $false }
        if ($cur) {
            $current = [pscustomobject]@{
                configured   = $true
                schedule     = @(Get-WBSchedule -Policy $cur | ForEach-Object { ([datetime]$_).ToString('HH:mm') })
                target       = (@(Get-WBBackupTarget -Policy $cur) | ForEach-Object { if ($_.Path) { "$($_.Path)" } else { "$($_.Label)" } }) -join ', '
                system_state = [bool](Get-WBSystemState -Policy $cur)
                bare_metal   = [bool](Get-WBBareMetalRecovery -Policy $cur)
                volumes      = @(Get-WBVolume -Policy $cur | ForEach-Object { "$($_.MountPath)" })
            }
        }
        if ($Pv) { return [pscustomobject]@{ current = $current } }
        $p = New-WBPolicy
        if ($SS) { Add-WBSystemState -Policy $p }
        if ($BMR) { Add-WBBareMetalRecovery -Policy $p }
        foreach ($vol in $V) { Add-WBVolume -Policy $p -Volume (Get-WBVolume -VolumePath $vol) }
        Set-WBSchedule -Policy $p -Schedule @($Sch | ForEach-Object { [datetime]::ParseExact($_, 'H:mm', $null) }) | Out-Null
        if ($T -like '\\*') { $bt = New-WBBackupTarget -NetworkPath $T -Credential $C } else { $bt = New-WBBackupTarget -VolumePath $T }
        Add-WBBackupTarget -Policy $p -Target $bt | Out-Null
        Set-WBPolicy -Policy $p -Force
        [pscustomobject]@{ current = $current }
    }
    $wanted = @{ schedule = @($Schedule); target = $Target; system_state = $SystemState; bare_metal = $BareMetal; volumes = @($Volumes) }
    $before = @{}
    foreach ($prop in $r.current.PSObject.Properties) { $before[$prop.Name] = $prop.Value }
    if ($Preview) {
        return @{
            summary = "Replace the scheduled backup policy on $ComputerName"
            changes = @(
                "Schedule: $(@($before.schedule) -join ', ') -> $($Schedule -join ', ')",
                "Target: $($before.target) -> $Target",
                "System state: $($before.system_state) -> $SystemState; bare metal: $($before.bare_metal) -> $BareMetal",
                "Set-WBPolicy -Force (replaces the existing policy)"
            )
            current = $before
        }
    }
    @{ host = $ComputerName; previous = $before; policy = $wanted }
}
```

- [ ] **Step 2: Update `plugin.yaml` `provides_tools`**: append these (keep the list sorted):

```yaml
  - backup_cancel
  - backup_jobs
  - backup_set_policy
  - backup_start
  - backup_status
  - backup_versions
```

- [ ] **Step 3: Run the suite**

Run: `.venv/bin/pytest`
Expected: all tests pass, and the contract test now covers the 6 backup scripts.

- [ ] **Step 4: Live smoke**. Use a member server that has the Windows Server Backup feature and a scratch target (a spare volume or a share the service account can write to).

```bash
SRV='<member server FQDN>'
TARGET='<\\NAS\share\path or E:>'
.venv/bin/python scripts/smoke.py backup_status
.venv/bin/python scripts/smoke.py backup_versions "{\"host\": \"$SRV\"}"
.venv/bin/python scripts/smoke.py backup_start "{\"host\": \"$SRV\", \"kind\": \"system_state\", \"target\": \"$TARGET\"}" --approve
.venv/bin/python scripts/smoke.py backup_jobs "{\"host\": \"$SRV\"}"
.venv/bin/python scripts/smoke.py backup_cancel "{\"host\": \"$SRV\"}" --approve
.venv/bin/python scripts/smoke.py backup_set_policy "{\"host\": \"$SRV\", \"schedule\": [\"23:00\"], \"target\": \"$TARGET\"}" --preview
```

Replace both placeholders before running. Expected results:
- Every call returns `"ok": true`.
- Right after `backup_start`, `backup_jobs` shows `current.running: true` and a `percent` once WSB reports one.
- `backup_status` shows `state: "run"` for that host until the job finishes or is cancelled.
- Hosts without the feature show `state: "none"`, and unreachable hosts are listed under `errors`.
- Run `backup_set_policy` only with `--preview` unless the host is a lab machine.

- [ ] **Step 5: Commit**

```bash
git add sysadmin/scripts plugin.yaml
git commit -m "feat: Windows Server Backup PowerShell scripts

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
