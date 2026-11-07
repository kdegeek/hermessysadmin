# Hermes Sysadmin v0.2: Windows and AD RMM and visibility. Design

**Status:** Approved design (2026-11-06). The implementation plan comes next.
**Builds on:** `2026-11-05-hermes-sysadmin-ad-design.md` (v0.1). That design still governs everything this one doesn't change.
**Deadline:** Hackathon entry Nov 11, 5 PM EST. Have a demo-ready slice of every part by Nov 10. Catalog breadth keeps growing after that.
**Live environment:** `corp.example.net`. 2 DCs (DC01 is the jump host, Server 2022). 41 enabled computers: 37 Windows 10/11 workstations and 4 servers. WinRM over HTTP (5985) answers on 14 of the 15 most recently active workstations, and RDP (3389) on most of them. HTTPS (5986) is closed on DC01.

## 1. Goal

Turn the plugin into an **agent-first Windows/AD RMM and visibility tool** that also has a full UI a person can drive:

1. **Fleet:** an inventory and health view of every computer, with snapshots kept over time.
2. **Catalog:** a broad, vetted, metadata-driven catalog of PowerShell actions. Most entries wrap cmdlets from in-box Windows/RSAT modules or pinned PowerShell Gallery modules. The agent uses the catalog (search, get, run) instead of writing ad-hoc PowerShell, and the dashboard turns every entry into a form.
3. **Overview:** charts for domain, fleet, security, GPO and backup posture, with trends.
4. **Remote access to desktops:** RDP, session shadowing, Remote Assistance and Quick Assist hand-off, a remote toolbox, and access diagnostics and fixes.
5. **Monitoring and alerts:** scheduled snapshots plus threshold alerts, delivered through Hermes cron. The agent can be woken to triage.

## 2. Decisions

| Topic | Decision |
|---|---|
| Endpoint reach | Agentless. Everything runs from the DC jump host, and per-machine work fans out with `Invoke-Command`/CIM over WinRM using the session's explicit credential (the existing `Get-HermesFanout`). Nothing is installed on endpoints. |
| Catalog source | **Wrap upstream modules.** (a) In-box Windows/RSAT modules, which need no install. (b) Pinned PowerShell Gallery modules, installed on the DC only at an exact version after a SHA-256 check against a committed lock file. Offensive and credential-dumping tooling is never included. |
| Catalog → agent | Three tools (`catalog_search`, `catalog_get`, `catalog_run`) rather than one tool per entry, so the agent's tool list stays small however large the catalog grows. |
| Catalog → UI | A generic Catalog page: categories, search, a parameter form generated from metadata, a target picker, preview, run, results table, CSV export. |
| Safety | Every catalog entry has a tier (R, W or H) and goes through the existing `Service.call()`: `decide()`, protected objects, approvals, audit and invalidation. A write that targets more than 10 machines, an OU, the whole fleet, or any domain controller escalates to H. Only `destructive: true` entries require typing the name. |
| Monitoring | A Hermes cron job in `--no-agent` watchdog mode runs the plugin's watch script. It writes a snapshot and prints only new or changed findings, and Hermes delivers that output to the channel the user picks. Optionally it runs in monitor mode, which wakes the agent to triage. |
| Charts | Hand-built SVG components in the desktop bundle, because the plugin can import only the Desktop SDK. |
| Desktop source | `desktop/plugin.js` stays one ESM file (the loader rejects relative imports). It is **built** by concatenating `desktop/src/NN-*.js` with `scripts/build_desktop.py`, and a test fails when the built file is stale. |

## 3. Architecture

### 3.1 New and changed files

```
catalog/
  modules.lock.json            # pinned Gallery modules: name, version, sha256, license, project URL
  <category>/<id>.ps1          # one entry per file: YAML metadata header + param() + Invoke-Op body
sysadmin/
  catalog.py                   # load + validate entries, register them as Ops ("cat.<id>"), search index
  fleet.py                     # snapshot store (plugin sqlite): write, latest, history, retention
  monitor.py                   # alert rules → findings; fingerprint dedupe; markdown output
  ops/fleet.py                 # fleet_inventory, fleet_device, fleet_history (R)
  ops/catalog.py               # catalog_search, catalog_get (R, local); catalog_module_status (R); catalog_module_install (H)
  ops/monitor.py               # monitoring_status (R, local), monitoring_enable / monitoring_disable (W, local)
  ops/remote.py                # remote access to desktops: sessions, shadow/RA command builders, access diagnostics
  tools.py                     # + catalog_run tool (dynamic tier), registered with the others
  hooks.py                     # catalog_run approvals use the target entry's decision
scripts/
  build_desktop.py             # desktop/src/*.js → desktop/plugin.js
  watch.py                     # the cron script body (imports sysadmin.monitor); a launcher copy goes to ~/.hermes/scripts/
  verify_live.py               # extended: fleet + catalog read entries, still forced read-only
desktop/src/NN-*.js            # source sections. The current §1–§16 are split mechanically, then new sections added.
skills/fleet-health-check/  skills/endpoint-triage/  skills/remote-assist/   # new workflow skills
```

### 3.2 Catalog entry format

Each entry is a single `.ps1` file. The existing contract lint and the pwsh parse check apply to it unchanged. Its metadata is a YAML block inside the first comment:

```powershell
<# hermes-catalog
id: endpoint.disk_usage                 # unique, dotted: <area>.<name>
title: Disk usage
category: Endpoint health               # one of the fixed categories in §5
description: Free and used space per fixed drive; flags drives under MinFreePercent.
module: inbox:Storage                   # inbox:<Module> | gallery:<Name>@<exact version>
target: endpoint                        # dc | endpoint
tier: R                                 # R | W | H
destructive: false                      # true => dashboard asks to type the target name
preview: none                           # none | plan (W/H entries must be plan)
columns: [host, drive, size_gb, free_gb, free_pct, low]
tags: [disk, storage, capacity]
source: "In-box Storage module (Get-Volume)"   # or upstream repo URL + SPDX license when adapted
params:
  - {name: MinFreePercent, type: integer, default: 10, minimum: 1, maximum: 90, description: Flag drives below this.}
#>
param([string[]]$Computers = @(), [string]$Ou, [int]$MinFreePercent = 10, [switch]$Preview)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($MinFreePercent) -Script {
        param($min)
        Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter } | ForEach-Object {
            [pscustomobject]@{ drive = "$($_.DriveLetter):"; size_gb = [math]::Round($_.Size/1GB,1)
                               free_gb = [math]::Round($_.SizeRemaining/1GB,1)
                               free_pct = if ($_.Size) { [math]::Round(100*$_.SizeRemaining/$_.Size,1) } else { 0 }
                               low = ($_.Size -and (100*$_.SizeRemaining/$_.Size) -lt $min) } }
    }
}
```

Rules:
- `target: endpoint` entries automatically get `Computers` (array) and `Ou` (string) parameters. They fan out through the new prelude helper `Invoke-HermesCatalogFanout`, which flattens per-host rows, adds `host`, and returns `@{ items; errors; summary = @{ hosts; ok; failed } }`. Its PSSession options are OpenTimeout 5 s and OperationTimeout 60 s, ThrottleLimit 16. `Get-HermesTargets` gains `-Kind Workstation|Server|Any`. For endpoint catalog entries the default is Workstation; the existing callers keep their server default.
- A `gallery:` entry calls `Use-HermesModule <Name> <Version>` before using the module. The helper imports `-RequiredVersion` from the plugin-managed path and throws `NotInstalled` with an install hint when the module is missing. Gallery modules run **on the DC only**. Endpoint entries use in-box cmdlets, CIM and COM inside the fan-out.
- The **plan** preview means: when `-Preview` is set, return `@{ summary; changes = @(...); current }` before changing anything (the v0.1 contract).
- `catalog.py` validates every header at load: unique id, a known category, the `module` grammar, params that match the `param()` block names, the tier/preview pairing, and a `gallery:` module that exists in `modules.lock.json`. An invalid entry is skipped and logged. In tests an invalid entry is a failure.
- Entries register as Ops named `cat.<id>`, flagged `catalog=True`. They are **not** registered as agent tools, so `provides_tools` lists only the three catalog tools. The dashboard's existing `/ops/{name}` routes run them unchanged.

### 3.3 Agent surface

- `catalog_search(query?, category?, target?, tier?, limit=20)` (R) returns `[{id, title, category, target, tier, params: [names], module}]`. The search scores id, title, tags and description tokens.
- `catalog_get(id)` (R) returns the full metadata: params with types, defaults and descriptions, columns, source and license, the module and whether it is installed, plus an example call.
- `catalog_run(id, params?, computers?, ou?)` runs `cat.<id>` through `Service.call`. The `pre_tool_call` hook evaluates the **entry's** decision (including the fleet escalation in §4) and gates `catalog_run` exactly as it gates a typed tool with that tier. The approval text shows the entry id and title, the targets, and the preview where one exists.
- The existing typed tools stay. Where a typed tool and a catalog entry overlap, the typed tool wins.
- `/ad catalog <query>`, `/ad run <id> key=value … [on HOST,HOST|ou=DN]`, and `/ad fleet [filter]`.
- Skills: `fleet-health-check` (an inventory then a ranked list of problems), `endpoint-triage` (a slow or broken PC: health entries, events, processes, then suggested fixes as catalog entries) and `remote-assist` (picking RDP, shadow or RA, and checking prerequisites). The existing skills are updated to mention catalog entries where one fits.

### 3.4 Fleet

- `fleet_inventory(ou?, kind=workstation|server|any, refresh=false)` (R, cache 10 min). It takes AD computer attributes (name, DNS name, OS, version, last logon date, OU, enabled) and adds a fan-out probe of every enabled computer: online, OS build, last boot and uptime, logged-on user, RAM, C: size and free space, pending reboot (CBS, WU and PendingFileRename keys), newest hotfix date, Defender (`Get-MpComputerStatus`: realtime on, signature age), BitLocker C: protection status, RDP enabled, NLA. An unreachable host stays in the list with `online=false` and the error message. The result is `{items, summary: {total, online, offline, pending_reboot, low_disk, patch_age_buckets, os_mix, defender_off, bitlocker_off}, taken_at}`.
- Every non-cached `fleet_inventory` run writes a snapshot row (`taken_at`, summary JSON, per-host JSON) to plugin sqlite through `fleet.py`. Snapshots are kept for 90 days.
- `fleet_device(computer)` (R): the same probe for one machine, plus local Administrators members, the top 5 processes by CPU and memory, stopped automatic services, the last 10 System/Application errors (24 h), and installed software count.
- `fleet_history(days=30)` (R): summary rows over time for the trend charts.

### 3.5 Remote access to desktops

- `remote_sessions(computers|ou)` (R): `quser`-style session list per machine (id, user, state, idle, logon time), using the same fan-out.
- `remote_shadow_command(computer, session_id, control=true, consent=true)` (R, local, no remote call) returns `mstsc /shadow:<id> /v:<host> [/control] [/noConsentPrompt]` plus a `.cmd` file body for download. No consent (`/noConsentPrompt`) is an **H** decision when the endpoint's shadow policy allows it. The UI explains that the shadow policy must permit it.
- `remote_assist_command(computer)` (R, local) returns `msra.exe /offerRA <host>` and a `.cmd` body. A Quick Assist note says the user opens Quick Assist and reads out the code; no remote call is needed.
- `remote_access_check(computer)` (R): RDP enabled, NLA, firewall rule group state, Remote Desktop Users members, the shadow policy value (`HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services\Shadow`), Remote Assistance (`fAllowUnsolicited`, `fAllowToGetHelp`), and the msra firewall rule. Each failing check names the catalog entry that fixes it.
- Fixes are catalog W entries with plan previews: `remote.enable_rdp`, `remote.set_nla`, `remote.add_rdp_user`, `remote.set_shadow_policy` (0–4), `remote.enable_remote_assistance`, `remote.open_rdp_firewall`. A target that is a DC escalates to H.
- The existing `rdp_connect_file` works for any computer name.
- Toolbox entries (endpoint target): processes, services, installed software, event errors, disk, logged-on user, `remote.send_message` (msg.exe, W), `remote.lock_workstation` (W), `remote.gpupdate` (W), `remote.restart_service` (W), `remote.logoff_session` (W), `remote.restart_computer` (H, plan preview lists the logged-on users), `remote.stop_process` (W).

### 3.6 Overview with charts

The SVG components are `Donut`, `BarList` (horizontal ranked bars), `Histogram`, `StackedBar`, `Sparkline` and `StatTile`. They use only `--ui-*` tokens plus a fixed 6-step series palette derived from them. Each has `role="img"` and an `aria-label` that carries the data as text, and each shows a value label so colour is never the only channel.

The Overview tab layout, top to bottom:
1. **KPI row.** Users (enabled/total), computers online/total, patch compliance (% with a hotfix in the last 35 days), pending reboots, backups OK/total, GPOs needing attention, open alerts.
2. **Fleet.** OS mix (Donut), last seen in AD (Histogram: <1 d, 1–7, 7–30, 30–90, >90 d), patch age (Histogram), lowest disk free (BarList, top 8, red under the alert threshold).
3. **Identity.** Account hygiene (StackedBar: enabled, disabled, locked, stale, never-expiring), privileged group membership (BarList), password expiry in the next 14 days (Histogram).
4. **Security posture.** Defender realtime off, BitLocker off, RDP on with NLA off, SMBv1 enabled. These are counts with drill-down links to a Fleet filter.
5. **Infrastructure.** DC health tiles, GPO health (Donut: OK, empty, unlinked, version mismatch), backup age per host (BarList).
6. **Trends** (from fleet history). Online %, patch compliance % and pending reboots over 30 days (Sparklines).

Every tile and chart segment is clickable and opens the matching filtered Fleet, Users, GPO or Backups view.

### 3.7 Fleet page and device drawer

- **Table columns:** name, OS, online, user, uptime, C: free, patch age, reboot pending, Defender, BitLocker, RDP.
- **Filters:** online/offline, low disk, reboot pending, patch age over 35 days, OS, OU, plus free-text search.
- **Multi-select:** a "Run catalog entry…" action applies to the selected machines and opens the Catalog run dialog with targets prefilled.
- **Device drawer tabs:**
  - *Summary:* the `fleet_device` result.
  - *Remote:* Connect (.rdp), sessions with Shadow and Offer RA buttons that give a copyable command and a `.cmd` download, access checks with Fix buttons, and toolbox actions.
  - *Run:* endpoint catalog entries filtered to this machine.
  - *History:* audit rows for this host.

### 3.8 Catalog page

- **Layout:** the left rail lists categories with counts. The main pane has search and an entry list (title, tier badge, target, module).
- **Entry detail:** description, source and license, module status with an Install button for a missing gallery module (an H op), a parameter form generated from metadata (`string`/`enum` as a select, `integer`, `boolean`, `array` as a chips input), and a target picker (DC; selected devices; OU; a fleet filter).
- **Actions:** Preview, for plan entries, shows the server preview. Run goes through the existing W/H confirm dialogs.
- **Results:** a table built from `columns`, with a per-host error list, CSV export and copy-as-JSON.

### 3.9 Monitoring and alerts

- **Settings** (added to `config_schema`): `monitor_interval` (default `30m`), `alert_disk_free_pct` (10), `alert_offline_days` (7), `alert_patch_age_days` (45), plus `alert_privileged_changes` and `alert_lockouts` (both true). Backup staleness reuses `backup_stale_days`.
- **`monitor.py`** evaluates the rules against a fresh snapshot and current domain data:
  - disk below threshold;
  - online last snapshot but offline now for longer than N days (by AD last logon);
  - patch age above N days;
  - pending reboot for more than 7 days;
  - Defender realtime turned off;
  - new members in privileged groups (diffed against the previous snapshot's membership);
  - currently locked-out users;
  - GPO health problems;
  - a stale or failed backup;
  - a DC health error.
- **Findings** have a fingerprint (`rule:host:value-bucket`). Only fingerprints that weren't active last run are printed. A cleared finding prints one "resolved" line. Output is short markdown. **Empty output means silence** (the Hermes watchdog contract).
- **Setup:** `monitoring_enable(deliver, mode=watchdog|agent)` (W, local) writes the launcher `~/.hermes/scripts/hermes_sysadmin_watch.py`, which imports the plugin's `scripts/watch.py`. It then creates the cron job with `hermes cron create <interval> --name hermes-sysadmin-watch --script hermes_sysadmin_watch.py --no-agent --deliver <target>`. In agent mode it uses `--monitor-script` with a triage prompt that uses the `fleet-health-check` skill instead. `monitoring_disable` removes the job. `monitoring_status` reports the job, its last run and open findings.
- **UI:** a Monitoring card on Overview (enabled state, interval, delivery target, last run, open alerts) with Enable/Disable buttons.

### 3.10 Pinned gallery modules

- **Lock file:** `catalog/modules.lock.json` lists, per module, `{name, version, package_hash (the PSGallery SHA-512 `PackageHash`, base64), license, project_url, signer (allow-listed Authenticode subject, or null when the module is unsigned), requires: [names]}`. Every dependency in the tree is its own pinned entry. Evotec modules declare minimum-version dependencies, so the lock pins each one exactly.
- **`catalog_module_install(name)`** (H, plan preview: version, source URL, hash, target path, and what is already installed):
  1. Download `https://www.powershellgallery.com/api/v2/package/<name>/<version>` to `C:\ProgramData\HermesSysadmin\Modules\staging\` (TLS 1.2). If the file is already there (an offline drop), use it.
  2. Check that `Get-FileHash -Algorithm SHA512` (base64) equals the lock's `package_hash`. On a mismatch, delete it and fail.
  3. Expand it into `C:\ProgramData\HermesSysadmin\Modules\<name>\<version>\`, dropping the NuGet metadata (`_rels`, `package`, `[Content_Types].xml`, `*.nuspec`).
  4. When `signer` is set, `Get-AuthenticodeSignature` on every `.psd1`/`.psm1`/`.ps1` must be `Valid` and from that signer. Unsigned modules rely on the hash pin plus code review when the lock is bumped.
  5. Install the `requires` modules first, the same way. Record what was installed in `installed.json` beside the modules.
- **No global installs.** Nothing goes into `Program Files`, the machine-level `PSModulePath` is never changed, and nothing runs `Install-Module` or `Update-Module`. `Use-HermesModule` prepends the plugin module root to `$env:PSModulePath` for its own runspace only, so pinned dependencies resolve. It then runs `Import-Module -Name <n> -RequiredVersion <v>`.
- **Status in v0.2.** The pinned-module mechanism ships for future modules that run locally on the jump host. The lock is empty in v0.2 (see §5.1), so `catalog_module_install` is disabled until a module is pinned.
- **Internet.** Only the install step needs the internet. An admin can instead place the `.nupkg` in the staging folder (an offline drop). Entries never use module features that download things (for example CDN-backed HTML output).
- **`catalog_module_status`** (R) lists each lock entry and whether it's installed and verified.

## 4. Safety additions

- **Fleet escalation.** For catalog (`cat.*`) and remote write entries, the decision becomes H when any of these hold:
  - targets exceed 10 machines;
  - `ou` is given;
  - no explicit computers are given and the entry would fall back to "all";
  - any target is a DC (the existing `_touches_dc`).
- **Hard target cap.** 200 machines (an existing `Get-HermesTargets` limit, kept).
- **`destructive: true`** entries require typing the name in the dashboard. The H tier alone no longer does (v0.1 change `ca63770`).
- **Gallery modules** never run on endpoints. Installing one is H and verified by hash.
- **Protected-object checks** (RID 500/502, DC accounts, critical system objects) are applied in catalog write entries that touch AD objects, through `Assert-HermesNotProtected`.
- **Lint.** The contract lint now covers `catalog/**/*.ps1`. One addition: `Invoke-WebRequest` is allowed only in the module-install script.
- **Excluded.** No credential-dumping, offensive or exploitation tooling. No module whose main purpose is attack simulation.

## 5. Catalog contents (target 60–80 entries by Nov 10)

Categories are fixed: Endpoint health, Security posture, Patching, Users & sessions, Remote access, Network, Printers, AD hygiene, Group Policy, DNS & DHCP, Certificates, Event logs, File permissions, Maintenance.

| Category | Entries (R unless marked) |
|---|---|
| Endpoint health | disk usage; uptime & last boot; pending reboot; top processes; stopped automatic services; installed software; startup items; recent System/Application errors; hardware summary (CPU, RAM, model, serial, BIOS); battery health (laptops) |
| Security posture | Defender status & signature age; BitLocker status; firewall profiles; local Administrators members; Windows LAPS status; SMBv1 state; TLS/SSL protocol settings; RDP NLA state; guest account state; Secure Boot & TPM state; AppLocker/WDAC state |
| Patching | hotfix history; pending updates (COM search, read-only); Windows Update/WSUS configuration; trigger scan (W, `UsoClient StartScan`); install updates via a scheduled task (H, plan) |
| Users & sessions | logged-on users; user profiles & sizes; send message (W); log off session (W); lock workstation (W) |
| Remote access | access check; enable RDP (W); set NLA (W); add Remote Desktop user (W); set shadow policy (W); enable Remote Assistance (W); open RDP firewall (W) |
| Network | IP configuration; DNS client servers; listening ports; test connection to host:port; SMB shares & sessions; Wi-Fi profiles (names only) |
| Printers | printers & ports; queue status; clear stuck queue (W); restart spooler (W) |
| AD hygiene | stale computers; stale users; never-expiring passwords; password-not-required accounts; reversible encryption; accounts with SPNs (kerberoastable surface); AS-REP roastable (no preauth); unconstrained delegation; empty groups; adminCount orphans; krbtgt password age; LAPS coverage; replication summary (`repadmin /replsummary` parse) |
| Group Policy | unlinked GPOs; empty GPOs; version mismatch AD/SYSVOL; GPO permission review; Gallery-module reports (see §5.1) |
| DNS & DHCP | zones & aging/scavenging; stale DNS records; DHCP scope utilization; leases for host |
| Certificates | expiring machine certificates (fleet); ADCS template audit (Gallery, read-only) |
| Event logs | failed logons (4625) summary; account lockouts (4740) with source; RDP logons (4624 type 10); service install events (7045); event search by ID/time |
| File permissions | NTFS access, orphaned SIDs, inheritance (in-box `Get-Acl` run locally on the file server through the fan-out; see §5.1) |
| Maintenance | gpupdate (W); restart service (W); flush DNS (W); clear temp folders (W, plan shows sizes); restart computer (H, plan) |

### 5.1 Gallery modules (pinned)

**No Gallery modules ship in v0.2.** The jump-host session is a non-delegating NTLM WinRM logon, so a Gallery module that runs on the jump host cannot authenticate to other machines (the double hop). NTFSSecurity was the last candidate: run against UNC paths it would need SMB to other file servers. The `files.*` entries are therefore implemented in-box: each takes a `Server` and a local `Path` and runs `Get-Acl` / `Get-ChildItem` on that server through the credentialed fan-out. `files.ntfs_effective_access` is dropped, because effective access cannot be computed reliably in-box without `Add-Type`. `catalog/modules.lock.json` is empty (`{"modules": []}`); the install/status machinery stays for future modules that run locally on the jump host.

Evaluated and **not** shipped in v0.2: NTFSSecurity@4.2.6 (MIT, unsigned; double hop against file servers, see above); Testimo (slow, may reach PSGallery on import); Locksmith (MIT plus Commons Clause; no ADCS confirmed in this domain); PSPKI (ADCS only; would exclude `Get-RequestArchivedKey`); Carbon (duplicates in-box cmdlets); BurntToast (archived, invisible from WinRM); kbupdate (needs internet, stale); DSInternals and PSWinDocumentation.AD (credential-dumping features, **never**); AdmPwd.PS and `Get-LapsADPassword` (return passwords, so excluded); PSWindowsUpdate (its -ComputerName mode needs DCOM plus delegated credentials from the jump host, which a non-delegating WinRM session cannot provide; in-box Windows Update Agent COM entries cover the same data); ADEssentials@1.0.7 (with PSEventViewer, PSWriteHTML, PSSharedGoods) and GPOZaurr@1.1.13 (their functions query other DCs/servers directly, which a non-delegating jump-host session cannot authenticate; the entries are implemented in-box with credentialed fan-out instead).

## 6. Error handling

New typed errors: `NotInstalled` (a gallery module is missing, with the install hint) and `PartialResult` (a fan-out where some hosts failed: `ok:true`, `errors[]` filled, and the UI shows a per-host error strip). A fan-out never fails as a whole because hosts are offline. The transport's fast-fail cooldown (v0.1, `6f23a91`) still applies to the jump host.

## 7. Testing

- **Unit:**
  - catalog loader: header schema, param/`param()` agreement, tier/preview pairing, unique ids, lock-file references, category list;
  - every entry passes the contract lint and the pwsh parse;
  - `catalog_run` approvals (dynamic tier, fleet escalation);
  - fleet snapshot store and retention;
  - monitor rules and fingerprint dedupe;
  - the remote command builders;
  - `build_desktop.py` freshness.
- **Desktop:** `node --check` on the built file. Chart components get pure-function tests for their geometry helpers, run with node's test runner.
- **Live:** `scripts/verify_live.py` keeps forcing read-only mode. It adds `fleet_inventory`, `fleet_device` (one online workstation), `remote_access_check`, `remote_sessions` and every R catalog entry against one online workstation and the DC, plus previews of a sample of W entries. **No live write runs without the user approving that specific action.**

## 8. Out of scope (v0.2)

Endpoint agents; patch deployment rings; software deployment; ticketing; multi-domain or multi-forest; a web view outside Hermes Desktop; installing Gallery modules on endpoints.
