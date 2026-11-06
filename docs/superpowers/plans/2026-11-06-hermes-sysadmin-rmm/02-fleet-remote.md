# Phase 2: Fleet and remote access

Relevant existing code:
- `Op.post` signature is `post(data, clean_args, settings)`. It runs on every call, **including cache hits** (`sysadmin/service.py`, line ~185).
- `Op.local` is `local(service, args)`.
- `Op.inject` is `inject(settings) -> dict` of extra PS params.
- Plugin storage: `from plugins.plugin_storage import plugin_db`, then `plugin_db(PLUGIN_ID, "<file>.db")` returns a `sqlite3.Connection`. See `sysadmin/audit.py:open_audit`, which falls back to an in-memory DB when the import fails (as it does in tests).

### Task 5: Fleet inventory, device detail, snapshot store, history

**Files:**
- Create: `sysadmin/fleet.py` (snapshot store and summary helpers)
- Create: `sysadmin/ops/fleet_ops.py`
- Create: `sysadmin/scripts/fleet_inventory.ps1`, `sysadmin/scripts/fleet_device.ps1`
- Modify: `sysadmin/ops/__init__.py` (import `fleet_ops`)
- Modify: `sysadmin/commands.py` (`/ad fleet [filter]`)
- Modify: `sysadmin/api.py`, `dashboard/plugin_api.py` (`GET /fleet`, `GET /fleet/{computer}`, `GET /fleet/history?days=`)
- Modify: `plugin.yaml` (`provides_tools` adds `fleet_device`, `fleet_history`, `fleet_inventory`)
- Test: `tests/test_fleet.py`

**Interfaces:**
- Produces:
  - `fleet.FleetStore(conn)` with:
    - `record(snapshot: dict) -> bool`. It stores `{taken_at, summary, items}`. If a row with the same `taken_at` already exists it returns False; otherwise it inserts and returns True.
    - `latest() -> dict | None`
    - `previous() -> dict | None` (the second-newest)
    - `history(days: int) -> list[{"taken_at", "summary"}]`, oldest first
    - `prune(days: int = 90) -> int`

    Table: `snapshots(taken_at TEXT PRIMARY KEY, summary TEXT, items TEXT)`.
  - `fleet.get_store() -> FleetStore` is a process singleton using `plugin_db("hermes-sysadmin", "fleet.db")`, falling back to `sqlite3.connect(":memory:", check_same_thread=False)`. `fleet.set_store(store)` is for tests.
  - `fleet.summarize(items, *, now, disk_pct: int) -> dict` returns:
    - `{"total","online","offline","pending_reboot","low_disk","defender_off","bitlocker_off","rdp_no_nla","patch_compliant","os_mix": {os: n},"patch_age_buckets": {"<7","7-35","35-90",">90","unknown"},"last_seen_buckets": {"<1d","1-7d","7-30d","30-90d",">90d","never"}}`
    - `low_disk` counts online hosts whose `c_free_pct < disk_pct`.
    - `patch_compliant` counts online hosts with `patch_age_days <= 35`.
    - `defender_off` counts `defender_rt is False`.
    - `bitlocker_off` counts `bitlocker` not in (`"on"`, `None`).
    - `rdp_no_nla` counts `rdp and nla is False`.
  - Op `fleet_inventory` (R, toolset `fleet`, `cache_ttl=600`, script `fleet_inventory`). Params: `ou` (string), `kind` (enum `workstation|server|any`, default `workstation`), `refresh` (boolean). Inject `ServerSearchBase` as `ad_rdp`'s `_search_base` does. Post: compute `summary` with `settings.alert_disk_free_pct` (Task 11 adds the field; use `getattr(settings, "alert_disk_free_pct", 10)`), then `get_store().record(...)` and `prune(90)`. Store failures are logged and never raised. It returns `{"items", "summary", "taken_at"}`. When `refresh` is true the service cache must be bypassed. Implement this in `Service._run_cached` with a generic rule: if `clean.get("refresh") is True`, skip the cache lookup but still store the result. Add a test in `tests/test_service.py` for that rule.
  - Item shape (one per AD computer, from the script):

    ```
    {"name","dns","os","os_version","ou","enabled","last_logon" (ISO or null),"online": bool,"error": str|null,
     "build","last_boot","uptime_days","user","ram_gb","c_size_gb","c_free_gb","c_free_pct","pending_reboot": bool,
     "reboot_reasons": [..],"last_hotfix" (ISO|null),"patch_age_days": int|null,"defender_rt": bool|null,
     "defender_sig_age_days": int|null,"bitlocker": "on"|"off"|"suspended"|"unknown"|null,"rdp": bool|null,"nla": bool|null}
    ```
  - Op `fleet_device` (R, toolset `fleet`, script `fleet_device`). Param: `computer` (string, required, ps `ComputerName`). It returns the item shape plus `admins: [names]`, `top_cpu: [{name,pid,cpu_s,ws_mb}]` (5), `top_mem` (5), `stopped_auto_services: [{name,display}]`, `recent_errors: [{time,log,source,id,message (≤300 chars)}]` (10, last 24 h), and `software_count`. Target: `args["computer"]`.
  - Op `fleet_history` (R, local). Param: `days` (integer, default 30, minimum 1, maximum 90 via an explicit check). It returns `{"items": store.history(days)}`.
  - API: `api.fleet(service, refresh=False)` calls `service.call("fleet_inventory", {"refresh": refresh}, actor="dashboard")` and returns the same envelope as the other API functions. `api.fleet_device(service, computer)` and `api.fleet_history(service, days)` work the same way.
  - `/ad fleet [offline|reboot|disk|patch|<text>]` gives the summary line plus up to 20 matching rows: `name · online · user · C: free% · patch age · flags`.

- [ ] **Step 1: Write the failing tests** (`tests/test_fleet.py`):

```python
import sqlite3
from datetime import datetime, timedelta, timezone

from sysadmin import fleet
from sysadmin.registry import OPS

NOW = datetime(2026, 11, 6, 12, tzinfo=timezone.utc)


def item(name, **kw):
    base = {"name": name, "online": True, "os": "Windows 11 Enterprise", "c_free_pct": 50, "patch_age_days": 10,
            "pending_reboot": False, "defender_rt": True, "bitlocker": "on", "rdp": False, "nla": True,
            "last_logon": (NOW - timedelta(hours=3)).isoformat()}
    base.update(kw)
    return base


def test_summary_counts():
    items = [item("A"), item("B", c_free_pct=5, pending_reboot=True), item("C", online=False, last_logon=None),
             item("D", defender_rt=False, bitlocker="off", rdp=True, nla=False, patch_age_days=100, os="Windows 10 Pro")]
    s = fleet.summarize(items, now=NOW, disk_pct=10)
    assert (s["total"], s["online"], s["offline"]) == (4, 3, 1)
    assert s["low_disk"] == 1 and s["pending_reboot"] == 1 and s["defender_off"] == 1
    assert s["bitlocker_off"] == 1 and s["rdp_no_nla"] == 1 and s["patch_compliant"] == 2
    assert s["os_mix"] == {"Windows 11 Enterprise": 3, "Windows 10 Pro": 1}
    assert s["patch_age_buckets"][">90"] == 1 and s["last_seen_buckets"]["never"] == 1


def test_store_record_dedupes_and_prunes():
    st = fleet.FleetStore(sqlite3.connect(":memory:"))
    old = (NOW - timedelta(days=120)).isoformat()
    assert st.record({"taken_at": old, "summary": {"total": 1}, "items": []})
    assert st.record({"taken_at": NOW.isoformat(), "summary": {"total": 2}, "items": [item("A")]})
    assert not st.record({"taken_at": NOW.isoformat(), "summary": {"total": 2}, "items": []})
    assert st.latest()["summary"]["total"] == 2 and st.previous()["summary"]["total"] == 1
    assert st.prune(90, now=NOW) == 1 and len(st.history(365, now=NOW)) == 1


def test_inventory_post_records_snapshot(make_service, runner):
    st = fleet.FleetStore(sqlite3.connect(":memory:"))
    fleet.set_store(st)
    runner.responses["fleet_inventory"] = {"taken_at": NOW.isoformat(), "items": [item("A")]}
    out = make_service().call("fleet_inventory", {}, actor="agent")
    assert out["ok"] and out["data"]["summary"]["total"] == 1 and st.latest() is not None


def test_ops_are_read_only():
    assert all(OPS[n].tier == "R" for n in ("fleet_inventory", "fleet_device", "fleet_history"))
```

`FleetStore.prune` and `.history` take an optional `now: datetime | None = None` (default `datetime.now(timezone.utc)`) for testability.

- [ ] **Step 2: Run them.** Expected: FAIL.

- [ ] **Step 3: Implement `sysadmin/fleet.py` and `sysadmin/ops/fleet_ops.py`** per the interfaces. Bucket rules:
  - `patch_age_buckets`: `None` → `unknown`; `<7`; `7-35` for 7–35 inclusive; `35-90` for 36–90; `>90`.
  - `last_seen_buckets` come from `last_logon` vs `now`: `<1d`, `1-7d`, `7-30d`, `30-90d`, `>90d`, and `never` when null.

- [ ] **Step 4: Scripts.** `fleet_inventory.ps1`:

```powershell
param([string]$Ou, [ValidateSet('workstation','server','any')][string]$Kind = 'workstation', [bool]$Refresh = $false, [string]$ServerSearchBase)
Invoke-Op {
    $kindMap = @{ workstation = 'Workstation'; server = 'Server'; any = 'Any' }
    $props = 'DNSHostName','OperatingSystem','OperatingSystemVersion','LastLogonDate','Enabled','DistinguishedName'
    $filter = switch ($Kind) { 'workstation' { "Enabled -eq 'True' -and OperatingSystem -notlike '*Server*'" } 'server' { "Enabled -eq 'True' -and OperatingSystem -like '*Server*'" } default { "Enabled -eq 'True'" } }
    $adArgs = @{ Filter = $filter; Properties = $props }
    if ($Ou) { $adArgs['SearchBase'] = $Ou }
    $ad = @(Get-ADComputer @adArgs | Select-Object -First 500)
    $names = @($ad | ForEach-Object { if ($_.DNSHostName) { $_.DNSHostName } else { $_.Name } })
    $probe = Invoke-HermesCatalogFanout -Computers $names -Script {
        $os = Get-CimInstance Win32_OperatingSystem
        $cs = Get-CimInstance Win32_ComputerSystem
        $c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
        $reasons = @()
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'CBS' }
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'WindowsUpdate' }
        $pfr = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
        if ($pfr) { $reasons += 'PendingFileRename' }
        $hf = Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
        $mp = $null; try { $mp = Get-MpComputerStatus -ErrorAction Stop } catch { }
        $bl = $null; try { $bl = (Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter "DriveLetter='C:'" -ErrorAction Stop).ProtectionStatus } catch { }
        $ts = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -ErrorAction SilentlyContinue
        $rdpTcp = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -ErrorAction SilentlyContinue
        [pscustomobject]@{
            build = "$($os.Version)"; last_boot = $os.LastBootUpTime.ToUniversalTime().ToString('o')
            uptime_days = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1)
            user = "$($cs.UserName)"; ram_gb = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
            c_size_gb = if ($c) { [math]::Round($c.Size / 1GB, 1) } else { $null }
            c_free_gb = if ($c) { [math]::Round($c.FreeSpace / 1GB, 1) } else { $null }
            c_free_pct = if ($c -and $c.Size) { [int][math]::Round(100 * $c.FreeSpace / $c.Size) } else { $null }
            pending_reboot = ($reasons.Count -gt 0); reboot_reasons = $reasons
            last_hotfix = if ($hf) { $hf.InstalledOn.ToUniversalTime().ToString('o') } else { $null }
            patch_age_days = if ($hf) { [int]((Get-Date) - $hf.InstalledOn).TotalDays } else { $null }
            defender_rt = if ($mp) { [bool]$mp.RealTimeProtectionEnabled } else { $null }
            defender_sig_age_days = if ($mp) { [int]$mp.AntivirusSignatureAge } else { $null }
            bitlocker = switch ($bl) { 1 { 'on' } 0 { 'off' } 2 { 'unknown' } default { $null } }
            rdp = if ($ts) { $ts.fDenyTSConnections -eq 0 } else { $null }
            nla = if ($rdpTcp) { $rdpTcp.UserAuthentication -eq 1 } else { $null }
        }
    }
    $byHost = @{}
    foreach ($p in $probe.items) { $byHost[$p['host'].ToLower()] = $p }
    $errByHost = @{}
    foreach ($e in $probe.errors) { $errByHost[$e.host.ToLower()] = $e.message }
    $items = @(foreach ($c in $ad) {
        $key = if ($c.DNSHostName) { $c.DNSHostName.ToLower() } else { $c.Name.ToLower() }
        $row = @{ name = $c.Name; dns = $c.DNSHostName; os = $c.OperatingSystem; os_version = $c.OperatingSystemVersion
            ou = ($c.DistinguishedName -replace '^CN=[^,]+,', ''); enabled = [bool]$c.Enabled
            last_logon = if ($c.LastLogonDate) { $c.LastLogonDate.ToUniversalTime().ToString('o') } else { $null }
            online = $byHost.ContainsKey($key); error = $errByHost[$key] }
        if ($byHost.ContainsKey($key)) { foreach ($k in $byHost[$key].Keys) { if ($k -ne 'host') { $row[$k] = $byHost[$key][$k] } } }
        $row
    })
    @{ taken_at = (Get-Date).ToUniversalTime().ToString('o'); items = $items }
}
```

  Check that `Invoke-HermesCatalogFanout`'s `PSComputerName` matches the names passed in. It does: Invoke-Command reports the name you gave it. Lower-casing on both sides handles case differences.

  `fleet_device.ps1` takes `param([Parameter(Mandatory)][string]$ComputerName)` and uses `Invoke-HermesOne -ComputerName $ComputerName -ScriptBlock {...}`. Check the prelude for `Invoke-HermesOne`'s exact parameter names and use them. Its block computes the same fields as the inventory probe (copy the block, since the scripts can't share a block) plus:
  - `admins = @(Get-LocalGroupMember -SID 'S-1-5-32-544' | % Name)`
  - `top_cpu` from `Get-Process | Sort CPU -Desc | Select -First 5`
  - `top_mem` sorted by WorkingSet64
  - `stopped_auto_services` from `Get-CimInstance Win32_Service -Filter "StartMode='Auto' AND State<>'Running'"`
  - `recent_errors` from `Get-WinEvent -FilterHashtable @{LogName='System','Application'; Level=1,2; StartTime=(Get-Date).AddHours(-24)} -MaxEvents 10`, with the message trimmed to 300 characters
  - `software_count` from both Uninstall registry hives (count of entries with a `DisplayName`)

  Add the AD fields with one `Get-ADComputer` call.

- [ ] **Step 5: Wire up** the API routes, `/ad fleet`, and the `plugin.yaml` tools. Update `tests/test_plugin.py` expectations if they enumerate tools.

- [ ] **Step 6: Run.** `.venv/bin/python -m pytest -q`. Expected: pass.

- [ ] **Step 7: Commit.** `git commit -m "feat: fleet inventory with snapshot history, device detail, /ad fleet and dashboard routes"` (add new files first).

---

### Task 6: Remote access to desktops

**Files:**
- Create: `sysadmin/ops/remote.py`
- Create: `sysadmin/scripts/remote_sessions.ps1`, `sysadmin/scripts/remote_access_check.ps1`
- Create: `catalog/remote/enable_rdp.ps1`, `set_nla.ps1`, `add_rdp_user.ps1`, `set_shadow_policy.ps1`, `enable_remote_assistance.ps1`, `open_rdp_firewall.ps1`, `send_message.ps1`, `lock_workstation.ps1`, `logoff_session.ps1`, `restart_computer.ps1`
- Modify: `sysadmin/ops/__init__.py`, `plugin.yaml` (`provides_tools` adds `remote_access_check`, `remote_assist_command`, `remote_sessions`, `remote_shadow_command`), `sysadmin/api.py` + `dashboard/plugin_api.py` (`GET /remote/{computer}/check`, `GET /remote/sessions?computers=a,b`, `GET /remote/{computer}/shadow?session_id=&control=&consent=`, `GET /remote/{computer}/assist`)
- Test: `tests/test_remote.py`

**Interfaces:**
- Consumes: the catalog entry format (Task 2), `parse_quser` and `_clean` from `sysadmin/ops/rdp.py`, and `Invoke-HermesCatalogFanout`.
- Produces:
  - `remote.shadow_command(host, session_id, control=True, consent=True) -> str`. It returns `mstsc.exe /shadow:<id> /v:<host>`, plus ` /control` when `control`, plus ` /noConsentPrompt` when not `consent`. `host` must match `^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$`, otherwise it raises `InvalidArguments`. `session_id` is an int ≥ 0.
  - `remote.assist_command(host) -> str` returns `msra.exe /offerRA <host>`, using the same host validation.
  - `remote.cmd_file(command, note) -> str` returns `"@echo off\r\nrem <note>\r\n<command>\r\n"`.
  - Op `remote_shadow_command` (R, local, toolset `remote`). Params: `computer` (required), `session_id` (integer, required, minimum 0), `control` (boolean, default true), `consent` (boolean, default true). `escalate` returns True when `consent is False`, so a no-consent shadow is an H decision because it lets an admin watch without the user knowing. `decide()` currently returns `allow` for every R op before it looks at `escalate` (`sysadmin/policy.py`, line ~143). Change it: an R op whose `escalate` returns True is decided as tier H. That means the protected-object check, then the mode check (read-only blocks), then approval. An R op without `escalate`, or whose `escalate` returns False, is still allowed straight away. Add a policy test for both cases in `tests/test_policy.py`. The op returns `{"command", "cmd_file", "filename": "shadow-<host>-<id>.cmd", "note": "Shadowing needs the endpoint's shadow policy to allow it (remote.set_shadow_policy) and RDP reachability. Run the .cmd on your admin PC."}`.
  - Op `remote_assist_command` (R, local). Param: `computer` (required). It returns `{"command", "cmd_file", "filename", "note": "Needs Remote Assistance enabled (remote.enable_remote_assistance). For Quick Assist, the user opens Quick Assist and reads you the code; nothing is needed here."}`.
  - Op `remote_sessions` (R, script). Params: `computers` (array, ps `Computers`), `ou` (string, ps `Ou`). The script fans out with `Invoke-HermesCatalogFanout` running `quser 2>$null` and returns raw lines per host. Post-processing with `parse_quser` turns them into `{"items": [{"host","user","id","state","idle","idle_minutes","logon"}], "errors": [...], "summary": {...}}`. Hosts with no sessions produce no rows.
  - Op `remote_access_check` (R, script). Param: `computer` (required, ps `ComputerName`). Via `Invoke-HermesOne` it returns `{"checks": [{"key","label","ok": bool|null,"value","fix": "<catalog id>"|null}]}` with keys in this order:
    1. `rdp_enabled` (fix `remote.enable_rdp`)
    2. `nla` (fix `remote.set_nla`)
    3. `rdp_firewall` (fix `remote.open_rdp_firewall`)
    4. `rdp_users` (value is the list of members, `ok` is null, fix `remote.add_rdp_user`)
    5. `shadow_policy` (value 0–4 or null; `ok` = value in 1..4; fix `remote.set_shadow_policy`)
    6. `ra_unsolicited` (fix `remote.enable_remote_assistance`)
    7. `ra_firewall` (fix `remote.enable_remote_assistance`)

    The rows come from Python post-processing of raw fields the script returns, so the fix mapping can be unit-tested.
  - Catalog entries (all `target: endpoint`, category `Remote access` or `Users & sessions` as noted, W with `preview: plan` unless noted). Each write script does this, in order:
    1. Resolve targets: `Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any`.
    2. If `$Preview`, fan out a read of the current value and return `@{summary; changes=@("<host>: <current> → <new>"); current=@{<host>=<current>}}`.
    3. Otherwise fan out the change and return the fan-out result.

    | id | category | params | change |
    |---|---|---|---|
    | `remote.enable_rdp` | Remote access | `Enabled` (boolean, default true) | `Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' fDenyTSConnections` (0/1) + `Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'` when enabling |
    | `remote.set_nla` | Remote access | `Required` (boolean, default true) | `...\WinStations\RDP-Tcp` `UserAuthentication` 1/0 |
    | `remote.add_rdp_user` | Remote access | `Members` (array, required) | `Add-LocalGroupMember -SID 'S-1-5-32-555' -Member $m` for each member; the preview lists current members; skip members already present |
    | `remote.set_shadow_policy` | Remote access | `Level` (integer, minimum 0, maximum 4, default 2) | `HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services` `Shadow` DWORD; the description explains 0 none, 1 full with consent, 2 full without consent, 3 view with consent, 4 view without consent |
    | `remote.enable_remote_assistance` | Remote access | `Unsolicited` (boolean, default true) | `HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance` `fAllowToGetHelp`=1, plus `HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services` `fAllowUnsolicited`=1/0 and `fAllowUnsolicitedFullControl`=1/0, plus `Enable-NetFirewallRule -DisplayGroup 'Remote Assistance'` |
    | `remote.open_rdp_firewall` | Remote access | none | `Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'` |
    | `remote.send_message` | Users & sessions | `Message` (string, required), `Seconds` (integer, default 60, minimum 5) | `msg.exe * /TIME:<s> <message>`. The message must be ≤ 255 characters with no newlines; the script throws otherwise. The preview lists the hosts and message |
    | `remote.lock_workstation` | Users & sessions | none | For each active console session: `rundll32.exe user32.dll,LockWorkStation` cannot cross sessions, so instead run `tsdiscon <id>` for the active session, which disconnects it and leaves it locked. The preview lists the sessions that will be disconnected |
    | `remote.logoff_session` | Users & sessions | `SessionId` (integer, required, minimum 0) | `logoff <id>`. The preview shows the user of that session |
    | `remote.restart_computer` | Maintenance | `Reason` (string, required), `DelaySeconds` (integer, default 300, minimum 0) | **tier H**. `shutdown.exe /r /t <s> /c <reason> /d p:0:0`. The preview lists the logged-on users per host (quser) |

    All of these are external executables or cmdlets. None uses the forbidden constructs.

- [ ] **Step 1: Write the failing tests** (`tests/test_remote.py`):

```python
import pytest

from sysadmin import catalog
from sysadmin.errors import InvalidArguments
from sysadmin.ops import remote
from sysadmin.policy import decide
from sysadmin.config import Settings
from sysadmin.registry import OPS


def test_shadow_command_flags():
    assert remote.shadow_command("PC1.corp", 3) == "mstsc.exe /shadow:3 /v:PC1.corp /control"
    assert remote.shadow_command("PC1", 3, control=False, consent=False) == "mstsc.exe /shadow:3 /v:PC1 /noConsentPrompt"


@pytest.mark.parametrize("bad", ["PC1 & calc", "-x", "", "a" * 300, "PC1\r\n"])
def test_bad_hosts_rejected(bad):
    with pytest.raises(InvalidArguments):
        remote.shadow_command(bad, 1)
    with pytest.raises(InvalidArguments):
        remote.assist_command(bad)


def test_no_consent_shadow_escalates():
    s = Settings(host="dc01", username="u", password="p")
    op = OPS["remote_shadow_command"]
    assert decide(op, {"computer": "PC1", "session_id": 1, "consent": True}, s).tier == "R"
    assert decide(op, {"computer": "PC1", "session_id": 1, "consent": False}, s).tier == "H"


def test_access_check_maps_fixes():
    raw = {"rdp_enabled": False, "nla": True, "rdp_firewall": False, "rdp_users": ["CORP\\bob"], "shadow": None,
           "ra_unsolicited": False, "ra_firewall": True}
    rows = remote.access_rows(raw)
    by = {r["key"]: r for r in rows}
    assert [r["key"] for r in rows] == ["rdp_enabled", "nla", "rdp_firewall", "rdp_users", "shadow_policy",
                                         "ra_unsolicited", "ra_firewall"]
    assert by["rdp_enabled"]["fix"] == "remote.enable_rdp" and by["rdp_enabled"]["ok"] is False
    assert by["shadow_policy"]["ok"] is False and by["rdp_users"]["ok"] is None


def test_sessions_post_parses_quser():
    data = {"items": [{"host": "PC1", "lines": [" USERNAME  SESSIONNAME  ID  STATE  IDLE TIME  LOGON TIME",
                                                ">bob       console       1  Active      none   11/6/2026 8:00 AM"]}],
            "errors": [], "summary": {"hosts": 1, "ok": 1, "failed": 0}}
    out = OPS["remote_sessions"].post(data, {}, None)
    assert out["items"][0] == {"host": "PC1", "user": "bob", "id": 1, "state": "active", "idle": "none",
                               "idle_minutes": 0, "logon": "11/6/2026 8:00 AM"}


def test_remote_fix_entries_registered():
    ids = {o.meta["id"] for o in catalog.entries()}
    assert {"remote.enable_rdp", "remote.set_nla", "remote.add_rdp_user", "remote.set_shadow_policy",
            "remote.enable_remote_assistance", "remote.open_rdp_firewall", "remote.restart_computer"} <= ids
    assert OPS["cat.remote.restart_computer"].tier == "H"
```

  Adjust `test_sessions_post_parses_quser`'s expected `session` key to match what `parse_quser` actually returns. It includes `"session": "console"`, so assert a subset with `items[0].items() >= {...}.items()` instead of equality.

- [ ] **Step 2: Run them.** Expected: FAIL.

- [ ] **Step 3: Implement** `remote.py`, both scripts and the 10 catalog entries. Each catalog entry is a full header plus a script, following `catalog/endpoint/uptime.ps1` from Task 2. Sample, for the pattern every write entry follows:

```powershell
<# hermes-catalog
id: remote.set_nla
title: Require Network Level Authentication
category: Remote access
description: Turns Network Level Authentication for Remote Desktop on (recommended) or off.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: W
preview: plan
columns: [host, before, after]
tags: [rdp, nla, remote desktop, security]
source: In-box registry (RDP-Tcp UserAuthentication)
params:
  - {name: Required, type: boolean, default: true, description: Require NLA.}
#>
param([string[]]$Computers = @(), [string]$Ou, [bool]$Required = $true, [switch]$Preview)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    $want = [int]$Required
    $read = Invoke-HermesCatalogFanout -Computers $targets -Script {
        [pscustomobject]@{ before = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp').UserAuthentication }
    }
    if ($Preview) {
        $cur = @{}; foreach ($r in $read.items) { $cur[$r['host']] = $r['before'] }
        return @{ summary = "Set NLA required=$Required on $($targets.Count) computer(s)"
                  changes = @($read.items | ForEach-Object { "$($_['host']): UserAuthentication $($_['before']) -> $want" }) + @($read.errors | ForEach-Object { "$($_.host): unreachable ($($_.message))" })
                  current = $cur }
    }
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($want) -Script {
        param($v)
        $k = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
        $before = (Get-ItemProperty $k).UserAuthentication
        Set-ItemProperty -Path $k -Name UserAuthentication -Value $v
        [pscustomobject]@{ before = $before; after = (Get-ItemProperty $k).UserAuthentication }
    }
}
```

- [ ] **Step 4: Wire up** the API routes and `plugin.yaml`.

- [ ] **Step 5: Run.** `.venv/bin/python -m pytest -q`. Expected: pass, including the shipped-catalog and parse tests.

- [ ] **Step 6: Commit.** `git commit -m "feat: remote access to desktops: sessions, shadow/RA commands, access checks with catalog fixes, toolbox entries"` (add new files first).
