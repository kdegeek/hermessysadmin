# Hermes Sysadmin — Active Directory / WinRM Plugin — Design

**Status:** Approved design, pending implementation plan
**Target:** Hermes Agent Plugin Hackathon (Nous Research) — catalog PR + ≤90 s demo
**Judging:** usefulness, reliability, polish, creativity; plugins that do more than a prompt/skill are favoured.

## 1. Goal

A Hermes Agent plugin that gives the agent and the human admin a safe, structured way to see and manage an on-prem Active Directory domain over WinRM. Four surfaces:

1. User management
2. GPO management
3. Remote Access / RDP
4. Backup control (Windows Server Backup)

Delivered as: ~50 typed agent tools, workflow skills, slash commands, a tiered approval policy, an audit log, and a Hermes Desktop dashboard.

No existing catalog plugin covers AD/WinRM administration (closest: `dashboard-auth-ldap` for login only; `hermes-windows-*` local read-only tools).

## 2. Decisions

| Topic | Decision |
|---|---|
| Environment | Real AD domain reachable over WinRM from the Hermes host |
| Backup | Windows Server Backup (`wbadmin` / `WindowsServerBackup` module) |
| RDP scope | Session management, RDP/NLA/Remote Desktop Users access control, `.rdp` Connect from dashboard. RDS infrastructure out of scope |
| GPO scope (V1) | Visibility + lifecycle (create/delete, link/unlink, enforce, enable/disable, security filtering, remote gpupdate, backup/restore). Settings editing and GPO diff out of scope |
| Connectivity | Jump-host model: one WinRM endpoint, which **must be a domain controller** (GroupPolicy cmdlets take no `-Credential`, so AD/GPO work stays local on the DC, avoiding the NTLM double hop). Per-host work fans out via `Invoke-Command` with an explicit PSCredential |
| Auth | NTLM default; HTTPS 5986 default, HTTP 5985 with message encryption as fallback; Kerberos selectable. Transport is pluggable for a future direct-to-host mode |
| UI | Hermes Desktop only (V1). Backend at `/api/plugins/hermes-sysadmin/` is reusable for a future web-dashboard tab |
| Safety | Tiered policy (strict) by default; permissive and read-only modes in settings |
| Tool approach | Typed tools over vetted PowerShell templates (core) + `ad_powershell` escape hatch, off by default |

## 3. Architecture

### 3.1 Package layout

```
hermes-sysadmin/
├── plugin.yaml              # manifest v2: provides_tools, provides_hooks, config_schema
├── __init__.py              # register(ctx): tools, hook, skills, slash commands
├── pyproject.toml           # pypsrp>=0.8,<1 (all deps upper-bounded)
├── sysadmin/
│   ├── transport.py         # WinRM session pool (pypsrp RunspacePool), reconnect, timeouts
│   ├── runner.py            # run_script(name, params) -> parsed JSON | typed error
│   ├── scripts/*.ps1        # vetted PS templates, one per operation, param() blocks
│   ├── policy.py            # risk-tier table, protected objects, modes
│   ├── audit.py             # SQLite audit log (plugin_db)
│   ├── cache.py             # short-TTL snapshot cache for dashboard reads
│   ├── errors.py            # typed error classes + to_result()
│   ├── ops/                 # pure-Python operation layer (no Hermes imports)
│   │   ├── domain.py users.py gpo.py rdp.py backup.py
│   ├── schemas.py tools.py  # thin agent-tool adapters over ops/
│   ├── commands.py          # slash command handlers
│   └── hooks.py             # pre_tool_call -> approve/block per policy
├── skills/<name>/SKILL.md
├── dashboard/
│   ├── manifest.json        # {"name": "hermes-sysadmin", "api": "plugin_api.py"}
│   └── plugin_api.py        # FastAPI router; calls ops/ via asyncio.to_thread
├── desktop/plugin.js        # Hermes Desktop page (ESM, SDK only, jsx()/jsxs())
└── tests/                   # unit (fake runner) + tests/live (opt-in)
```

### 3.2 Data flow

Agent tool **or** dashboard action → `Service.call()` → `policy.decide()` → cache → `runner.run()` → pypsrp → jump host → PowerShell (AD/GPO cmdlets locally; per-host work via `Invoke-Command -ThrottleLimit`) → JSON → normalised result → audit entry (writes) → `broadcast_plugin_event("hermes-sysadmin", "changed", {...})`.

**Key boundary:** `ops/` is the single source of truth and has no Hermes dependency. Tools and API routes are thin wrappers, so the agent and dashboard cannot drift, and `ops/` is testable with a fake runner.

### 3.3 Script execution contract

- Each operation is a `.ps1` file with a `param()` block. Inputs are passed as serialized parameters via pypsrp `add_parameter` — **never string-interpolated**.
- Scripts set `$ErrorActionPreference = 'Stop'`, wrap their body in try/catch, and emit exactly one JSON object: `{"ok": true, "data": ...}` or `{"ok": false, "error": {"type", "message", "category", "target"}}` via `ConvertTo-Json -Depth 6 -Compress`.
- Write scripts that support previews accept `-Preview` (not `-WhatIf`, which many AD/GP cmdlets interpret themselves) and return `{summary, changes, current}` without making a change.
- A session prelude runs once per runspace pool: it defines the shared helpers, sets `$PSDefaultParameterValues` for `Invoke-Command:Credential` / `*-AD*:Credential`, and pins `*-GP*:Server` to the local DC.

### 3.4 Configuration (`config_schema`, auto-rendered in Settings → Plugins)

- Connection: `host`, `port` (default 5986), `use_https` (default true), `auth` (`ntlm` | `kerberos`, default `ntlm`), `username`, `password` (secret, `env: SYSADMIN_WINRM_PASSWORD`), `verify_tls` (default true).
- Scope: `server_search_base` (OU DN used for "all servers" fan-out), `backup_stale_days` (default 7).
- Safety: `mode` (`strict` | `permissive` | `read-only`, default `strict`), `protected_objects` (list of sAMAccountNames/DNs, appended to built-in defaults), `privileged_groups` (appended to built-in defaults), `enable_powershell_escape` (default false).
- Secrets read only via `agent.secret_scope.get_secret`; never from `.env` or credential stores directly.

## 4. Safety policy

Every tool and API action declares a tier in one table in `policy.py`.

| Tier | Examples | strict | permissive | read-only |
|---|---|---|---|---|
| R — read | list, get, report, status | run | run | run |
| W — write | reset password, unlock, disable, link GPO, logoff session, start backup | approval | run | block |
| H — high-risk | delete object, privileged-group change, GPO delete/restore, RDP disable on a DC, backup policy change, `ad_powershell` | approval + preview | approval + preview | block |
| Protected | any write targeting krbtgt, built-in Administrator, DC computer objects, configured denylist | block | block | block |

- **Escalation:**
  - `ad_group_add_member` and `ad_group_remove_member` escalate W→H when the group is privileged. Privileged groups are Domain Admins, Enterprise Admins, Schema Admins, Administrators, Account/Server/Backup/Print Operators, Group Policy Creator Owners and DnsAdmins, plus any configured ones.
  - `rdp_set_enabled`, `rdp_set_nla`, `rdp_users_add` and `rdp_users_remove` escalate when a target is a DC. An unknown DC list counts as a DC.
  - `rdp_set_nla` also escalates when it disables NLA.
  - `gpo_link`, `gpo_unlink` and `gpo_set_link` escalate at the domain root, the Domain Controllers OU or a site.
  - `gpo_set_status` and `gpo_set_security_filter` escalate for the Default Domain and Default Domain Controllers policies.
- **Agent path:** `pre_tool_call` hook returns `{"action": "approve", "message": ..., "rule_key": ...}`. For W-tier, `rule_key` is `hermes-sysadmin:<tool>`, so "always allow" can cover a W tool. For H-tier, it is `hermes-sysadmin:<tool>:once:<uuid>`, so an "always" never matches a later high-risk call. Blocks are left to the handler (`Service.call`), which audits them once. For H-tier, the hook runs the `-Preview` and includes it in the approval message. Hook exceptions fail closed (Hermes default).
- **Dashboard path:** same `policy.decide()`. UI shows `ConfirmDialog`; H-tier shows the preview and requires typing the object name. API write routes require `confirm: true` (and for H-tier, `confirm_name` matching the target), so a bare request cannot bypass the dialog.
- **Headless runs** (cron / single-query / unattended): Hermes denies approvals by default; tools return a clear "requires interactive approval" error.
- Permissive mode only skips the plugin's own W-tier approval request; it never auto-approves, never disables Hermes guards (catalog rule 12).
- **Audit:** every W/H attempt (allowed, denied, blocked, failed) is logged: timestamp, actor (`agent:<session_id>` or `dashboard`), tool, target, redacted params, tier, decision, result summary.
- **Redaction:** password parameters and generated passwords never appear in the audit log, logs, or tool output except the one-time result returned to the requester.

## 5. Agent tools

All return JSON strings; never raise. Toolsets let users disable surfaces.

### `ad_domain`
- R `ad_domain_overview` — domain/forest functional levels, FSMO holders, DC list, object counts.
- R `ad_dc_health` — per DC: replication summary, uptime, NTDS/DNS/Netlogon/KDC service state, SYSVOL share, time skew.
- R `ad_search` — LDAP filter or name search across users/groups/computers/OUs, paged.
- R `ad_dc_list` (cached; feeds DC escalation), `ad_connection_test` (modules present, rights probe, privileged memberships of the service account, warnings).

### `ad_users`
- R `ad_user_get` (groups, lockout, password expiry, last logon), `ad_user_list` (filters: OU, disabled, locked, stale N days, password expired, never-expires, privileged), `ad_lockout_source` (event 4740 on PDC emulator → caller computer).
- W `ad_user_create`, `ad_user_update` (attribute allowlist), `ad_user_reset_password` (generate or supplied; optional change-at-next-logon), `ad_user_unlock`, `ad_user_enable`, `ad_user_disable`, `ad_user_move`.
- W→H `ad_group_add_member`, `ad_group_remove_member`.
- R `ad_group_get`, `ad_group_list`.
- H `ad_user_delete`.
- R `ad_recycle_bin_list`; W `ad_recycle_bin_restore` (requires Recycle Bin enabled; reports clearly if not).

### `ad_gpo`
- R `gpo_list` (links, enforced, status), `gpo_get`, `gpo_report` (XML report parsed into key settings summary), `gpo_health` (unlinked, empty, all-settings-disabled, AD/SYSVOL version mismatch), `gpo_rsop` (user/computer), `gpo_backups` (backups taken by the plugin, stored on the DC under `%ProgramData%\HermesSysadmin\GpoBackups`).
- W `gpo_create`, `gpo_link`, `gpo_unlink`, `gpo_set_link` (enforce/enable), `gpo_set_status`, `gpo_set_security_filter`, `gpo_backup`, `gpo_update_hosts` (remote gpupdate by host list or OU).
- H `gpo_delete`, `gpo_restore` — both take an automatic backup first.

### `ad_rdp`
- R `rdp_sessions` (by host / OU / all servers; parsed `quser`), `rdp_host_status` (RDP enabled, NLA, firewall rule, Remote Desktop Users members).
- W `rdp_session_logoff`, `rdp_session_disconnect`, `rdp_session_message`, `rdp_set_enabled` (H on DCs), `rdp_set_nla`, `rdp_users_add`, `rdp_users_remove`.
- R `rdp_connect_file` — generates `.rdp` content for a host.

### `ad_backup`
- R `backup_status` (per host: feature installed, policy, last success, last system-state, next scheduled), `backup_versions`, `backup_jobs` (current job progress + recent event history).
- W `backup_start` (system state, or full/volume to configured policy target; returns job handle), `backup_cancel`.
- H `backup_set_policy`.
- Restores are out of V1; covered by guidance skill.

### Escape hatch and meta
- H `ad_powershell` — hidden from the agent (`check_fn`) and blocked by policy unless `enable_powershell_escape` is true; approval every call; full script shown in the approval message.
- R `sysadmin_audit_log` — query recent changes.

## 6. Skills

Workflow skills that chain typed tools:

- `onboard-user` — create from template user/role (groups, OU), initial password, optional RDP access, summary.
- `offboard-user` — disable, random password reset, strip groups (recorded in audit for restore), move to Disabled OU, log off RDP sessions, stamp description with date/ticket.
- `lockout-triage` — find source, inspect source host sessions/services, unlock, explain cause.
- `gpo-change` — backup → change → gpupdate on test host → RSoP verify → rollback on failure.
- `domain-health-check` — DCs, replication, backup staleness, GPO health, privileged membership → report.
- `access-review` — privileged group members, RDP rights per host, password-never-expires accounts.
- `backup-recovery-guide` — system-state and authoritative restore runbook.

## 7. Slash commands

Deterministic, no LLM round-trip: `/ad status`, `/ad user <name>`, `/ad unlock <name>` (confirms via `ctx.ask_choice`, passes through the same policy and audit), `/ad sessions [host]`, `/ad backups`.

## 8. Desktop dashboard

**Approved UI reference:** [`docs/superpowers/mockups/dashboard.html`](../mockups/dashboard.html) (interactive; open in a browser). The implementation must match its layout, tab set, drawer, dialogs (W confirm, H preview + type-to-confirm, reset-password one-time reveal), first-run card, and status-bar item. Mock tokens approximate `--ui-*`; the plugin uses the host's real variables.

Registered via `desktop/plugin.js`: one `SIDEBAR_NAV_AREA` entry "Active Directory" + `ROUTES_AREA` page; a status-bar health dot (green/amber/red from `ad_dc_health`); palette entries ("AD: Find user…", "AD: Unlock user…", "AD: Sessions").

Tabs:

1. **Overview** — KPI tiles (users total/disabled/locked/expiring in 7 days, computers, GPOs, active RDP sessions, hours since last good system-state backup); DC health table; last 10 audit entries. Tiles deep-link to filtered views.
2. **Users** — searchable table, filter chips (locked, disabled, stale, expiring, privileged); detail drawer (attributes, groups, lockout + source); actions Unlock, Reset password, Enable/Disable, Move, Add to group, Delete; New user dialog; Recycle Bin sub-view with Restore.
3. **Group Policy** — GPO table with links, status, health warnings; detail drawer (links, security filtering, parsed settings report); actions Link/Unlink, Enforce, Enable/Disable, Backup, Restore (from backups list), Delete, Run gpupdate on OU/host.
4. **Remote Access** — sessions grid (user, host, state, idle, logon time) with Log off / Disconnect / Message; Hosts view with RDP/NLA toggles and Remote Desktop Users; Connect button writes a `.rdp` file and opens it via SDK file/open helpers.
5. **Backups** — per-host cards (last success, last system-state, next run, current job progress), Back up now / Cancel, versions list; amber/red when older than `backup_stale_days`.
6. **Audit** — full write log with actor, session, tool, redacted params, decision, result, time.

Behaviour:
- Data via the SDK's query helpers over `ctx.rest`; backend snapshot cache with 30–60 s TTL; manual refresh always available.
- Live updates: backend broadcasts `plugin.hermes-sysadmin.changed` after writes; dashboard invalidates affected queries. Polling fallback when sockets are unavailable.
- Writes use `ConfirmDialog`; H-tier shows the `-Preview` result and type-to-confirm.
- Styling only via `var(--ui-*)` theme variables.
- First-run: setup card linking to Settings plus Test connection.

### Backend API (`dashboard/plugin_api.py`)

Async FastAPI routes mounted at `/api/plugins/hermes-sysadmin/`, each running `sysadmin/api.py` via `asyncio.to_thread`. One generic op route replaces per-resource routes, so the API can never drift from the op registry:

- `GET /health`
- `POST /test-connection`
- `GET /ops` (catalog)
- `POST /ops/{name}/decision` (`action`, `tier`, `reason`, `needs_preview`, `target`, `confirm_name`)
- `POST /ops/{name}/preview`
- `POST /ops/{name}`, with body `{args, confirm, confirm_name}`
- `GET /overview` (KPIs, DC health, last 10 audit rows, per-section errors)
- `GET /audit`
- `POST /refresh`

Write routes enforce the confirm contract in §4. Every response is HTTP 200 with `{ok, data}` or `{ok: false, error}`.

## 9. Error handling

- Typed errors: `ConnectionError` (unreachable, TLS, auth), `PermissionDenied`, `NotFound`, `PolicyBlocked`, `RemoteScriptError` (PS error record), `Timeout`.
- Tool/API result shape on failure: `{"ok": false, "error": {"type", "message", "hint"}}`; hints are agent-actionable (e.g. "Account lacks rights to reset passwords in OU=Staff; ask a Domain Admin or delegate").
- Transport: pooled runspace with health check and reconnect; one retry on transient network errors **for reads only**; writes never auto-retried. Timeouts: 30 s default; backups return a job handle and are polled.
- Fan-out operations report per-host errors; one failing host never fails the whole call.

## 10. Testing

- **Unit (pytest):** `ops/`, `policy`, `hooks`, `audit`, `commands`, API routes against a `FakeRunner` with recorded JSON fixtures. Covers the full policy matrix across modes, privileged-group escalation, protected-object blocks, redaction, error mapping, confirm contract.
- **Script checks:** every `.ps1` parses under `pwsh` (PS parser AST), has a `param()` block, and conforms to the output contract; a lint fails on string-interpolated inputs.
- **Live (opt-in, `SYSADMIN_LIVE=1`):** read-only by default; write tests create and clean up `zz-hermes-test-*` user and GPO in a dedicated test OU.
- **Plugin validation:** `hermes plugins validate . --install-deps`, `hermes plugins doctor --ci`, `node --check desktop/plugin.js`.
- **CI (GitHub Actions):** pytest + PS parse checks + validate + JS syntax; catalog screenshots.

## 11. Build steps

1. **Foundation** — package skeleton, manifest, config schema; transport, runner, errors, script contract; connect to the real domain via the jump host; FakeRunner test harness.
2. **Policy and audit** — tier table, modes, protected objects, privileged escalation, `pre_tool_call` hook, audit log, redaction.
3. **Domain + Users** — scripts, ops, tools, tests.
4. **GPO** — scripts, ops, tools, tests.
5. **Remote Access / RDP** — scripts, ops, tools, tests.
6. **Backup** — scripts, ops, tools, tests.
7. **Escape hatch, slash commands, skills.**
8. **Backend API** — routes, cache, confirm contract, change events.
9. **Desktop dashboard** — shell, sidebar, status bar, palette, then Overview → Users → Group Policy → Remote Access → Backups → Audit tabs; first-run setup.
10. **Live verification** — live test suite against the domain; fix reliability issues.
11. **Polish and packaging** — README, screenshots, CI green, `hermes plugins validate` / `doctor` clean.
12. **Submission** — record ≤90 s demo, open catalog PR (`plugin-catalog/hermes-sysadmin.yaml` with pinned SHA and rule-13 disclosures), submit form.

## 12. Demo script (≤90 s)

1. Desktop → AD dashboard: DCs green, 3 locked users.
2. Chat: "Bob says he's locked out again — figure out why." → lockout triage finds a stale RDP session on SRV-APP02 → approval → logoff + unlock → Bob's row turns green live.
3. "Add Bob to Domain Admins." → H-tier approval with preview → deny.
4. "Roll out the screensaver-lock GPO to the Finance OU." → backup, link, gpupdate, RSoP verify, visible in GPO tab.
5. Backups tab: SRV-FS01 system-state 9 days old (red) → Back up now → job progress → Audit tab.

## 13. Prerequisites from the user

- WinRM-enabled **domain controller** as the jump host, reachable from the Hermes host; WinRM enabled on member servers used for RDP/backup/gpupdate fan-out.
- Service account, ideally delegated admin rather than Domain Admin.
- Dedicated test OU for live tests.
- Hermes Agent + Hermes Desktop installed locally for validation.

## 14. Out of scope (V1)

GPO settings editing and diff; RDS infrastructure (Gateway, collections, licensing); backup restores; third-party backup products; direct per-host WinRM; Kerberos-first setup; web dashboard tab; Entra/Azure AD.

## 15. Catalog disclosures (rule 13)

Network: WinRM to the configured jump host only. Shell: no local shell; PowerShell executes remotely. Reads outside plugin data: none. Writes outside plugin data: GPO backups on the DC under `%ProgramData%\HermesSysadmin\GpoBackups`; a `.rdp` file in a user-chosen folder from the Connect button. Credentials: stored via Hermes secrets only. Background processes: none (dashboard polling is client-driven; backups are server-side jobs).
