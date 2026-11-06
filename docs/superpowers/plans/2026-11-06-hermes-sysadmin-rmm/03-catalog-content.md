# Phase 3: Catalog content

Tasks 7–10 each add one batch of catalog entries. They share the rules below. Every task's brief includes this preamble.

## Shared rules for every catalog entry

- **File and id.** Each entry is `catalog/<area>/<name>.ps1`, and its id is `<area>.<name>`. The full header format, the loader validation and the shipped-entry tests come from Task 2. `tests/test_catalog_shipped.py` and the contract lint pick new files up automatically.
- **Endpoint R pattern** (`target: endpoint`):

```powershell
param([string[]]$Computers = @(), [string]$Ou, <entry params>)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation   # -Kind Any for entries that also make sense on servers
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @(<entry params>) -Script {
        param(<same names>)
        # one [pscustomobject] per row; keep values scalar (strings, numbers, bools) or small arrays
    }
}
```

- **DC R pattern** (`target: dc`). This runs on the jump host with the ActiveDirectory, GroupPolicy, DnsServer or DhcpServer module. It returns `@{ items = @(<hashtables>) ; summary = @{...} }`. Fleet params are not added.
- **Gallery pattern.** The first statement inside `Invoke-Op` is `Use-HermesModule -Name <Name> -Version <ver>`. Then call the module's cmdlet and project only the columns listed in the header into hashtables. **Never return a raw module object.** Raw objects can be huge or circular, and some carry secrets.
- **Write pattern** (W/H, `preview: plan`). Same as `catalog/remote/set_nla.ps1` (Task 6):
  1. Read the current state with the fan-out.
  2. If `$Preview`, return `@{summary; changes; current}`.
  3. Otherwise apply the change and return before/after rows.
- **Output rules.** Columns in the header must be keys the rows actually carry; `host` is added by the fan-out. Event messages are trimmed to 300 characters. Lists are capped (`Select-Object -First 200` per host unless the entry says otherwise). No entry returns a password, hash, recovery key, LAPS secret or `cpassword` value.
- **Tags.** Include the obvious synonyms people search for, e.g. `[disk, storage, space, free]`.
- **Source.** `In-box <module or tool>`, or `PSGallery <Name> <ver> (<license>)`.
- **Verification per entry.** Run `/opt/homebrew/bin/pwsh -NoProfile -File scripts/ps_parse_check.ps1 -Path catalog` and the pytest suite. Live verification is Task 16 (read-only on HERMES-1).

---

### Task 7: Endpoint health, sessions and maintenance entries

**Files:** `catalog/endpoint/*.ps1`, `catalog/sessions/*.ps1` and `catalog/maint/*.ps1`. The two seed entries (`endpoint.disk_usage`, `endpoint.uptime`) already exist from Task 2.

**Interfaces.** Produces exactly these ids (Task 16 verifies them live and the UI lists them):

| id | tier | category | params | what it does |
|---|---|---|---|---|
| `endpoint.pending_reboot` | R | Endpoint health | — | CBS / WU / PendingFileRename / pending computer rename reasons → `pending, reasons` |
| `endpoint.top_processes` | R | Endpoint health | `Top` int 10, `SortBy` enum cpu\|memory | `name, pid, cpu_s, ws_mb, user` (`Get-Process -IncludeUserName` falls back without user when not elevated) |
| `endpoint.stopped_auto_services` | R | Endpoint health | — | `Win32_Service` StartMode Auto and not running, excluding delayed/trigger-start services whose ExitCode is 0 → `name, display, exit_code` |
| `endpoint.installed_software` | R | Endpoint health | `Filter` string | Both Uninstall hives (64- and 32-bit) → `name, version, publisher, installed` (yyyyMMdd → ISO); filter by name substring |
| `endpoint.startup_items` | R | Endpoint health | — | `Win32_StartupCommand` → `name, command, location, user` |
| `endpoint.recent_errors` | R | Endpoint health | `Hours` int 24, `Max` int 25 | System+Application Level 1,2 → `time, log, source, id, message` |
| `endpoint.hardware` | R | Endpoint health | — | `Win32_ComputerSystem`, `Win32_BIOS`, `Win32_Processor` → `manufacturer, model, serial, bios, cpu, cores, ram_gb` |
| `endpoint.battery` | R | Endpoint health | — | `Win32_Battery` + `root\wmi BatteryFullChargedCapacity/BatteryStaticData` → `present, charge_pct, health_pct` (`present=false` on desktops) |
| `sessions.logged_on` | R | Users & sessions | — | `quser` parsed in PowerShell → `user, session, id, state, idle, logon` |
| `sessions.user_profiles` | R | Users & sessions | `MinDaysUnused` int 0 | `Win32_UserProfile` (not Special) → `user` (SID translated), `last_use, size_mb` (size from `Get-ChildItem -Recurse -File -ErrorAction SilentlyContinue \| Measure Length`, capped to 60 s per host via the operation timeout) |
| `maint.gpupdate` | W | Maintenance | `Force` bool true | `gpupdate.exe /target:computer [/force]`; the preview lists the hosts |
| `maint.restart_service` | W | Maintenance | `Name` string required | `Restart-Service -Name`. Refuses the names `WinRM`, `RpcSs`, `LSM`, `TermService` with a thrown error (the WinRM case would cut the session). The preview shows the current status |
| `maint.flush_dns` | W | Maintenance | — | `Clear-DnsClientCache` |
| `maint.clear_temp` | W | Maintenance | `OlderThanDays` int 7 | Deletes files older than N days under `C:\Windows\Temp` and each `C:\Users\*\AppData\Local\Temp`. The preview shows `files, mb` per host. The run removes with `-ErrorAction SilentlyContinue` and reports the freed MB |

`remote.restart_computer`, `remote.send_message`, `remote.lock_workstation` and `remote.logoff_session` already exist from Task 6. Do not duplicate them.

- [ ] **Step 1: Write the test** `tests/test_catalog_batches.py`:

```python
from sysadmin import catalog

BATCH_7 = {"endpoint.pending_reboot", "endpoint.top_processes", "endpoint.stopped_auto_services",
           "endpoint.installed_software", "endpoint.startup_items", "endpoint.recent_errors", "endpoint.hardware",
           "endpoint.battery", "sessions.logged_on", "sessions.user_profiles", "maint.gpupdate",
           "maint.restart_service", "maint.flush_dns", "maint.clear_temp"}


def ids():
    return {o.meta["id"]: o for o in catalog.entries()}


def test_batch_7_present_with_tiers():
    got = ids()
    assert BATCH_7 <= set(got)
    assert {i for i in BATCH_7 if got[i].tier != "R"} == {"maint.gpupdate", "maint.restart_service",
                                                          "maint.flush_dns", "maint.clear_temp"}


def test_restart_service_refuses_winrm_in_script():
    text = (catalog.CATALOG_DIR / "maint" / "restart_service.ps1").read_text()
    assert "WinRM" in text and "throw" in text
```

- [ ] **Step 2: Run it.** Expected: FAIL.
- [ ] **Step 3: Write the 14 entries.**
- [ ] **Step 4: Run** pytest (full suite). Expected: pass.
- [ ] **Step 5: Commit.** `git add catalog tests && git commit -m "feat(catalog): endpoint health, sessions and maintenance entries"`

---

### Task 8: Security posture and patching entries

**Files:** `catalog/security/*.ps1` and `catalog/patch/*.ps1`.

| id | tier | target | params | what it does |
|---|---|---|---|---|
| `security.defender_status` | R | endpoint | — | `Get-MpComputerStatus` → `realtime, antivirus, tamper_protected, sig_age_days, sig_version, last_quick_scan` |
| `security.bitlocker_status` | R | endpoint | — | `Win32_EncryptableVolume` (all fixed volumes) → `drive, protection, conversion_pct, method`. **No recovery keys** |
| `security.firewall_profiles` | R | endpoint | — | `Get-NetFirewallProfile` → `profile, enabled, inbound_default, outbound_default` |
| `security.local_admins` | R | endpoint | — | `Get-LocalGroupMember -SID S-1-5-32-544` → `member, type, source` |
| `security.laps_status` | R | endpoint | — | Windows LAPS policy registry (`HKLM:\SOFTWARE\Microsoft\Policies\LAPS`, `...\CurrentVersion\LAPS\Config`) and legacy `AdmPwd` CSE presence → `windows_laps, legacy_laps, backup_directory`. **Never reads a password** |
| `security.smb1` | R | endpoint | — | `Get-SmbServerConfiguration` `EnableSMB1Protocol` + optional feature state → `smb1_server, feature` |
| `security.tls_protocols` | R | endpoint | — | SCHANNEL Protocols registry for SSL 3.0 / TLS 1.0 / 1.1 / 1.2 Client+Server `Enabled`/`DisabledByDefault` → one row per protocol: `protocol, server, client` (`default` when unset) |
| `security.rdp_nla` | R | endpoint | — | `rdp, nla, port` |
| `security.guest_account` | R | endpoint | — | `Get-LocalUser` SID `-501` → `name, enabled` |
| `security.secure_boot_tpm` | R | endpoint | — | `Confirm-SecureBootUEFI` (try/catch → `unsupported`) + `Get-Tpm` → `secure_boot, tpm_present, tpm_ready, tpm_version` (`Win32_Tpm` `SpecVersion`) |
| `security.applocker_wdac` | R | endpoint | — | AppIDSvc status, `Get-AppLockerPolicy -Effective` rule-collection counts, CodeIntegrity `UsermodeCodeIntegrityPolicyEnforcementStatus` (`Win32_DeviceGuard`) → `applocker_rules, appidsvc, wdac_user_mode` |
| `patch.hotfix_history` | R | endpoint | `Days` int 90 | `Get-HotFix` within N days → `kb, description, installed_on, installed_by` |
| `patch.pending_updates` | R | endpoint | — | COM `Microsoft.Update.Session` → `CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0")` → `title, kb, severity, size_mb, reboot`. Read-only: search only. Note that the COM searcher may be denied over WinRM on some builds; in that case the entry returns the error per host, which is fine |
| `patch.wu_config` | R | endpoint | — | `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate` (+ `\AU`) → `wsus_server, use_wsus, au_options, no_auto_update, target_group` |
| `patch.trigger_scan` | W | endpoint | — | `UsoClient.exe StartScan`; the preview lists the hosts |
| `patch.wu_pending` | R | endpoint | — | **Gallery**: `Use-HermesModule PSWindowsUpdate 2.2.1.5` on the DC, then `Get-WindowsUpdate -ComputerName $targets` (the module's own remoting; it needs no fan-out). Note: this runs the module on the DC against remote computers, so `Get-HermesTargets` is still used and `Invoke-HermesCatalogFanout` is not → `host, kb, title, size, status` |
| `patch.wu_history` | R | endpoint | `Last` int 20 | Gallery `Get-WUHistory -ComputerName -Last` → `host, date, kb, title, result` |
| `patch.wu_reboot_status` | R | endpoint | — | Gallery `Get-WURebootStatus -ComputerName -Silent` → `host, reboot_required` |
| `patch.wu_settings` | R | endpoint | — | Gallery `Get-WUSettings -ComputerName` → `host` + the setting keys flattened |
| `patch.wu_install` | H | endpoint | `Category` enum security\|critical\|both (default both), `AutoReboot` bool false | Scheduled install with the in-box Windows Update Agent (details below) |

**`patch.wu_install` design.** It must **not** use PSWindowsUpdate's `Invoke-WUJob`: that copies the module to the endpoint, which spec §3.10 forbids. Instead, through `Invoke-HermesCatalogFanout`, each target registers and immediately starts a one-shot scheduled task, `HermesSysadmin-WUInstall`, running as SYSTEM:
- The task runs `powershell.exe -NoProfile -NonInteractive -EncodedCommand <b64>`. `<b64>` is `[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))`, where `$body` is chosen by `if` from **constant** here-strings in the entry (one per Category × AutoReboot combination, or one constant with literal category GUID filters selected by `if`). No user text is ever inserted into the command.
- The constant body uses `New-Object -ComObject Microsoft.Update.Session` → `CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0")`. It keeps updates whose `Categories` contain `0FA1201D-4330-4FA8-8AE9-B877473B6441` (security) and/or `E6CF1350-C01B-414D-A61F-263D14D133B4` (critical), then downloads and installs them, and calls `shutdown.exe /r /t 300` only in the AutoReboot variant.
- The header uses `module: inbox:ScheduledTasks`, `tier: H` and `preview: plan`. The preview runs the same COM search, read-only, through the fan-out and lists `host: KB… title` per update. The run returns `host, task_registered, updates_queued`.
- The source is `In-box Windows Update Agent COM API via a SYSTEM scheduled task`.

- [ ] **Step 1: Test.** Add `BATCH_8` (the 20 ids above) to `tests/test_catalog_batches.py`, plus:

```python
def test_batch_8_present():
    got = ids()
    assert BATCH_8 <= set(got)
    assert got["patch.wu_install"].tier == "H" and got["patch.wu_install"].meta["module"] == "inbox:ScheduledTasks"
    assert got["patch.wu_pending"].meta["module"] == "gallery:PSWindowsUpdate@2.2.1.5"


def test_no_secret_cmdlets_anywhere():
    banned = ("Get-LapsADPassword", "Get-AdmPwdPassword", "Get-BitLockerRecoveryKey", "msFVE-RecoveryPassword",
              "ms-Mcs-AdmPwd", "msLAPS-Password", "Get-RequestArchivedKey", "cpassword =", "Invoke-WUJob")
    for f in catalog.CATALOG_DIR.glob("*/*.ps1"):
        text = f.read_text()
        assert not [b for b in banned if b in text], f
```

  `Invoke-WUJob` is banned because it pushes the module to endpoints. `gpo.gpp_password_exposure` (Task 9) must detect `cpassword` without the literal `cpassword =`. Use a regex like `'cpassword="[^"]+'` match counts, which never prints the value.

- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Write the 20 entries.**
- [ ] **Step 4: Run** the full suite. Expected: pass.
- [ ] **Step 5: Commit.** `git commit -m "feat(catalog): security posture and patching entries"` (add files first)

---

### Task 9: AD hygiene, Group Policy, DNS and DHCP entries

**Files:** `catalog/ad/*.ps1`, `catalog/gpo/*.ps1` and `catalog/dns/*.ps1`. All are `target: dc`.

| id | tier | params | what it does |
|---|---|---|---|
| `ad.stale_computers` | R | `Days` int 90 | enabled computers with `LastLogonDate` older than N days (or never) → `name, os, last_logon, ou` |
| `ad.stale_users` | R | `Days` int 90 | enabled users, same → `sam, name, last_logon, ou` |
| `ad.never_expiring_passwords` | R | — | `PasswordNeverExpires` enabled users → `sam, name, password_last_set` |
| `ad.password_not_required` | R | — | `userAccountControl` bit 0x20 → `sam, enabled` |
| `ad.reversible_encryption` | R | — | UAC 0x80 → `sam, enabled` |
| `ad.spn_accounts` | R | — | user objects with `servicePrincipalName` (excluding krbtgt) → `sam, spns (first 5), admin_count, password_last_set` |
| `ad.asrep_roastable` | R | — | UAC 0x400000 (DONT_REQ_PREAUTH) → `sam, enabled` |
| `ad.unconstrained_delegation` | R | — | `TrustedForDelegation` computers and users, excluding DCs → `name, class` |
| `ad.empty_groups` | R | — | groups with no members, excluding built-in critical objects → `name, scope, category` |
| `ad.admincount_orphans` | R | — | `adminCount=1` users that are not (recursively) in any protected group → `sam, enabled` |
| `ad.krbtgt_age` | R | — | krbtgt `PasswordLastSet` → `password_last_set, age_days` |
| `ad.laps_coverage` | R | — | per computer: has `msLAPS-PasswordExpirationTime` or `ms-Mcs-AdmPwdExpirationTime` (expiration attributes **only**) → `name, windows_laps, legacy_laps, expires`. **Never requests the password attributes** |
| `ad.replication_summary` | R | — | `repadmin.exe /replsummary` parsed into `source_dsa, largest_delta, fails, total, pct_error`, plus `Get-ADReplicationFailure -Scope Forest` rows |
| `ad.dfs_health` | R | — | Gallery ADEssentials 1.0.7 `Get-WinADDFSHealth` → its `DomainController, Status, IsPDC, GroupPolicyCount, SYSVOLCount, DFSErrors, DFSLocalSetting` columns (projected) |
| `ad.last_backup` | R | — | Gallery `Get-WinADLastBackup` → `naming_context, last_backup, days_since` |
| `ad.duplicate_spn` | R | — | Gallery `Get-WinADDuplicateSPN` → `spn, count, objects` |
| `ad.trusts` | R | — | Gallery `Get-WinADTrust` → `trust_source, trust_target, direction, type, status` |
| `ad.password_policies` | R | — | `Get-ADDefaultDomainPasswordPolicy` + `Get-ADFineGrainedPasswordPolicy -Filter *` → `name, precedence, min_length, max_age_days, lockout_threshold, complexity`. In-box, not Gallery |
| `ad.kerberos_accounts` | R | — | Gallery `Get-WinADKerberosAccount` → `domain, name, password_last_set, age_days` (projected) |
| `ad.fsmo_available` | R | — | Gallery `Test-FSMORolesAvailability` → `role, holder, available` |
| `gpo.unlinked` | R | — | GPOs with no links (`Get-GPOReport -ReportType Xml` LinksTo empty) → `name, modified` |
| `gpo.empty` | R | — | user and computer versions are both 0 → `name, created` |
| `gpo.version_mismatch` | R | — | AD vs SYSVOL versions (`Get-GPO` `User/Computer.DSVersion` vs `SysvolVersion`) → `name, scope, ad, sysvol` |
| `gpo.permissions` | R | — | `Get-GPPermission -All` for each GPO, flagging GPOs where Authenticated Users / Domain Computers lack Read → `name, trustee, permission, flag` |
| `gpo.broken` | R | — | Gallery GPOZaurr 1.1.13 `Get-GPOZaurrBroken` → `name, status, domain` |
| `gpo.permission_analysis` | R | — | Gallery `Get-GPOZaurrPermissionAnalysis` → projected `name, permission_type, principal, permission` |
| `gpo.link_summary` | R | — | Gallery `Get-GPOZaurrLinkSummary` → projected columns |
| `gpo.owners` | R | — | Gallery `Get-GPOZaurrOwner` → `name, owner, owner_type, is_admin` |
| `gpo.netlogon_files` | R | — | Gallery `Get-GPOZaurrNetLogon` → `path, owner, size, modified` (no content) |
| `gpo.sysvol_dfsr` | R | — | Gallery `Get-GPOZaurrSysvolDFSR` → projected columns |
| `gpo.gpp_password_exposure` | R | — | Scans `\\<domain>\SYSVOL\<domain>\Policies\*\{Machine,User}\Preferences\**\*.xml` for the `cpassword="…"` attribute **pattern count only** → `gpo_guid, gpo_name, file, matches`. Never emits a value. In-box (`Select-String -Pattern 'cpassword="[^"]+' -AllMatches`, counting `.Matches.Count`) |
| `dns.zones` | R | — | `Get-DnsServerZone` + `Get-DnsServerZoneAging` → `zone, type, ds_integrated, aging, refresh, no_refresh` |
| `dns.stale_records` | R | `Zone` string required, `Days` int 30 | dynamic A records with timestamp older than N days → `name, ip, timestamp` |
| `dhcp.scope_utilization` | R | — | `Get-DhcpServerv4ScopeStatistics` on each DHCP server from `Get-DhcpServerInDC` → `server, scope, in_use, free, pct` (errors per server when the module or server is missing) |
| `dhcp.leases_for_host` | R | `Name` string required | lease search by hostname substring across all scopes → `server, scope, ip, mac, hostname, expires` |

ADEssentials-based entries use `module: gallery:ADEssentials@1.0.7`; GPOZaurr-based entries use `gallery:GPOZaurr@1.1.13`. All other entries are `inbox:ActiveDirectory`, `inbox:GroupPolicy`, `inbox:DnsServer` or `inbox:DhcpServer`. Do **not** call any ADEssentials function that reaches PingCastle, or `Get-WinADBitlockerLapsSummary` with password output. (`ad.bitlocker_laps_coverage` from the spec is replaced by the in-box `ad.laps_coverage` above, which reads expiration attributes only.)

If a Gallery cmdlet name above does not exist in the pinned version, check it with `pwsh -c "Find-Command -ModuleName ADEssentials -RequiredVersion 1.0.7"` (read-only gallery query) or by inspecting the downloaded nupkg from Task 4's staging area. Then pick the closest existing cmdlet and note the change in your report. Do not add an entry with an invented cmdlet.

- [ ] **Step 1: Test.** Add `BATCH_9` (the 35 ids) with an assertion that every id is present, is tier R and is `target: dc`. Also assert that the text of every Gallery entry contains `Use-HermesModule`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Write the entries.**
- [ ] **Step 4: Run** the full suite.
- [ ] **Step 5: Commit.** `git commit -m "feat(catalog): AD hygiene, Group Policy (in-box + GPOZaurr/ADEssentials) and DNS/DHCP entries"`

---

### Task 10: Network, printers, certificates, event logs and file permissions

**Files:** `catalog/network/*.ps1`, `catalog/printers/*.ps1`, `catalog/certs/*.ps1`, `catalog/events/*.ps1` and `catalog/files/*.ps1`.

| id | tier | target | params | what it does |
|---|---|---|---|---|
| `network.ip_config` | R | endpoint | — | `Get-NetIPConfiguration` → `interface, ipv4, gateway, dns, dhcp` |
| `network.dns_client` | R | endpoint | — | `Get-DnsClientServerAddress -AddressFamily IPv4` → `interface, servers` |
| `network.listening_ports` | R | endpoint | — | `Get-NetTCPConnection -State Listen` + owning process name → `port, address, process, pid` |
| `network.test_port` | R | endpoint | `Target` string required, `Port` int required (1–65535) | from each endpoint: `Test-NetConnection -ComputerName $Target -Port $Port -WarningAction SilentlyContinue` → `target, port, tcp_ok, latency_ms` |
| `network.smb_shares` | R | endpoint | — | `Get-SmbShare` (not special) + `Get-SmbSession` count → `share, path, sessions` |
| `network.wifi_profiles` | R | endpoint | — | `netsh wlan show profiles` parsed → `profile` (names only; never `key=clear`) |
| `printers.list` | R | endpoint | — | `Get-Printer` + `Get-PrinterPort` → `name, driver, port, port_host, shared, status` |
| `printers.queue` | R | endpoint | — | `Get-PrintJob` for each printer → `printer, id, document, user, status, pages, submitted` |
| `printers.clear_queue` | W | endpoint | `Printer` string required | `Get-PrintJob -PrinterName \| Remove-PrintJob`. The preview lists the jobs. Mark `destructive: false` (the jobs belong to users but are transient) |
| `printers.restart_spooler` | W | endpoint | — | `Restart-Service Spooler`; the preview shows the queued job count |
| `certs.expiring` | R | endpoint | `Days` int 30 | `Cert:\LocalMachine\My` with `NotAfter` within N days → `subject, thumbprint, not_after, days_left, issuer` |
| `certs.adcs_templates` | R | dc | — | in-box AD read of `CN=Certificate Templates,CN=Public Key Services,CN=Services,<config NC>` → `name, display, schema, enroll_flags, ra_signatures, eku`, flagging `ENROLLEE_SUPPLIES_SUBJECT` + client-auth EKU with no manager approval as `risky=true`. Read-only. (Replaces the Gallery ADCS audit, since Locksmith/PSPKI are not shipped) |
| `events.failed_logons` | R | dc | `Hours` int 24 | Security 4625 on each DC (`Get-WinEvent -ComputerName <dc> -FilterHashtable`), grouped → `account, source_ip, workstation, count, last` |
| `events.lockouts` | R | dc | `Hours` int 24 | 4740 on the PDC → `account, caller_computer, time` |
| `events.rdp_logons` | R | endpoint | `Hours` int 24 | Security 4624 LogonType 10 → `user, source_ip, time` |
| `events.service_installs` | R | endpoint | `Days` int 7 | System 7045 → `service, path, account, time` |
| `events.search` | R | endpoint | `Log` enum System\|Application\|Security, `Id` int required, `Hours` int 24, `Max` int 50 | `time, id, provider, level, message` |
| `files.ntfs_access` | R | dc | `Path` string required (UNC or local path on the DC) | Gallery NTFSSecurity 4.2.6 `Get-NTFSAccess -Path` → `account, rights, type, inherited, applies_to` |
| `files.ntfs_effective_access` | R | dc | `Path` required, `Account` required | `Get-NTFSEffectiveAccess` → `account, rights` |
| `files.ntfs_orphaned_sids` | R | dc | `Path` required, `Depth` int 2 (maximum 5) | `Get-ChildItem2 -Directory -Depth`, then `Get-NTFSOrphanedAccess` → `path, sid, rights` (first 500 rows) |
| `files.ntfs_inheritance` | R | dc | `Path` required, `Depth` int 2 | `Get-NTFSInheritance` on each folder, flagging disabled inheritance → `path, access_inherited, audit_inherited` |

`network.test_port` must validate `Target` against `^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$` in the script (throw otherwise).

- [ ] **Step 1: Test.** Add `BATCH_10` (21 ids) with presence and tiers (`printers.clear_queue`, `printers.restart_spooler` are W; everything else is R), plus:

```python
def test_catalog_size_and_categories():
    ops = catalog.entries()
    assert len(ops) >= 95
    assert {o.meta["category"] for o in ops} == set(catalog.CATEGORIES)
```

- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Write the entries.**
- [ ] **Step 4: Run** the full suite.
- [ ] **Step 5: Commit.** `git commit -m "feat(catalog): network, printers, certificates, event logs, NTFS permissions entries"`
